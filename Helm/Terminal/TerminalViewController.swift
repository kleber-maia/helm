import AppKit
import SwiftTerm

/// Immutable primitive-only proof for a last-second off-main activity check.
struct TerminalRemovalProof: Sendable
{
  let pid: Int32
  let seconds: UInt64
  let microseconds: UInt64
  let shell: String

  func stillAppearsIdle() -> Bool
  {
    if pid == 0 { return true }
    var identity = HelmProcessIdentity()
    identity.seconds = seconds
    identity.microseconds = microseconds
    return HelmOwnedShellAppearsIdle(pid, identity, shell)
  }
}

/// A self-contained terminal emulator view controller backed by SwiftTerm.
/// Embed as a child view controller to use in any panel, window, or tab.
final class TerminalViewController: NSViewController
{
  private var terminalView: HelmProcessTerminalView!
  var geometryReady: (() -> Void)?
  private var geometryScheduled = false
  private var geometryForcePending = false
  private var geometryPhase = "layout"
  private var synchronizingGeometry = false
  private var lastGeometrySignature: String?
  private var lastSizingDiagnostic: String?
  var directoryChanged: ((URL?) -> Void)?
  var sessionStateChanged: (() -> Void)?
  private(set) var reportedDirectory: URL?
  private var directoryObserver: TerminalProcessDirectoryObserver?
  private var directoryGeneration = 0
  private var hasOSC7Directory = false

  /// The working directory the shell starts in.
  private(set) var workingDirectory: String
  private(set) var boundWorkingDirectory: String?

  var restartDirectory: String {
    let root = boundWorkingDirectory ?? workingDirectory
    if let reportedDirectory {
      let path = GitWorktreeCatalog.canonical(reportedDirectory.path)
      let bound = GitWorktreeCatalog.canonical(root)
      if path == bound || path.hasPrefix(bound + "/") { return reportedDirectory.path }
    }
    return root
  }

  func bindWorkingDirectory(_ path: String)
  {
    boundWorkingDirectory = path
    if processStarted { workingDirectory = path }
  }

  /// Shell executable. Defaults to the user's login shell.
  let shell: String

  /// The coding agent to launch inside the terminal.
  private(set) var agent: CodingAgent

  init(workingDirectory: String,
       agent: CodingAgent = .terminal,
       shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
  {
    self.workingDirectory = workingDirectory
    self.agent = agent
    self.shell = shell
    super.init(nibName: nil, bundle: nil)
  }

  @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

  override func loadView()
  {
    // SwiftTerm preserves the viewport while reading scrollback and resumes
    // following output when the user scrolls back to the bottom.
    let terminal = HelmProcessTerminalView(frame: .zero)
    let terminalFont = NSFont.monospacedSystemFont(ofSize: 13,
                                                   weight: .regular)

    terminal.font = terminalFont
    terminal.scrollerStyle = .overlay
    terminal.geometryDidSettle = { [weak self] in
      self?.requestGeometrySynchronization(phase: "nativeAttachOrResizeEnd", force: true)
    }
    terminal.nativeForegroundColor = .textColor
    terminal.nativeBackgroundColor = .textBackgroundColor
    terminal.caretColor = .controlAccentColor
    terminal.translatesAutoresizingMaskIntoConstraints = false
    terminalView = terminal
    terminal.processDelegate = self

    // TerminalBackground fills the padding area with the terminal background
    // color so the 8pt inset looks like internal content padding rather than
    // an external border.
    let container = TerminalBackground()

    container.addSubview(terminal)

    let padding: CGFloat = 8
    NSLayoutConstraint.activate([
      terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
      terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
      terminal.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
      terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor,
                                       constant: -padding),
    ])

    view = container
  }

  private var sessionClosed = false
  private var processStarted = false
  var hasStartedProcess: Bool { processStarted }
  private var ownedProcessIdentity: HelmProcessIdentity?

  var hasRunningProcess: Bool {
    isViewLoaded && (terminalView?.process?.shellPid ?? 0) > 0
  }

  /// Only a plain, owned foreground shell without children can be offered
  /// for explicitly approved closure. Shell builtins cannot be identified as
  /// idle by process metadata; the removal confirmation states that limitation.
  var worktreeRemovalStamp: String? {
    guard hasRunningProcess else { return "stopped" }
    let knownShells = ["zsh", "bash", "sh", "fish", "ksh", "dash", "tcsh", "csh"]
    guard agent == .terminal, knownShells.contains(URL(fileURLWithPath: shell).lastPathComponent),
          let identity = ownedProcessIdentity else { return nil }
    let pid = terminalView.process.shellPid
    guard HelmOwnedShellAppearsIdle(pid, identity, shell) else { return nil }
    return "\(pid):\(identity.seconds):\(identity.microseconds)"
  }

  var worktreeRemovalProof: TerminalRemovalProof? {
    guard hasRunningProcess else {
      return .init(pid: 0, seconds: 0, microseconds: 0, shell: shell)
    }
    guard worktreeRemovalStamp != nil, let identity = ownedProcessIdentity else { return nil }
    return .init(pid: terminalView.process.shellPid, seconds: identity.seconds,
                 microseconds: identity.microseconds, shell: shell)
  }

  func removalDirectoryIsInside(_ root: String) -> Bool
  {
    guard hasRunningProcess else { return true }
    guard let identity = ownedProcessIdentity else { return false }
    var buffer = [CChar](repeating: 0, count: 4096)
    guard HelmOwnedProcessDirectory(terminalView.process.shellPid, identity,
                                    &buffer, buffer.count) else { return false }
    let path = GitWorktreeCatalog.canonical(String(cString: buffer))
    return path == root || path.hasPrefix(root + "/")
  }

  /// Starts the terminal process if it has not already been started.
  func startIfNeeded()
  {
    guard !sessionClosed, !processStarted
    else { return }

    // The delayed start alone is not a layout guarantee. Fit the renderer to
    // the final host before forkpty snapshots the initial winsize.
    view.window?.contentView?.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    guard synchronizeGeometry(phase: "beforeStart", force: true) else { return }
    processStarted = true
    let launch = buildLaunchCommand()
    directoryGeneration += 1
    hasOSC7Directory = false
    terminalView.startProcess(executable: shell, args: ["-c", launch],
                              environment: nil, execName: nil)
    var identity = HelmProcessIdentity()
    ownedProcessIdentity = HelmOwnedProcessIdentity(terminalView.process.shellPid, &identity) ? identity : nil
    synchronizeProcessSize(phase: "afterStart")
    let generation = directoryGeneration
    let observer = TerminalProcessDirectoryObserver(pid: terminalView.process.shellPid) {
      [weak self] directory in
      guard let self, self.directoryGeneration == generation,
            !self.hasOSC7Directory,
            let local = RepositorySession.validDirectory(directory.path)
      else { return }
      self.reportedDirectory = local
      self.directoryChanged?(local)
    }
    directoryObserver = observer
    terminalView.setProcessOutputHandler { [weak observer] in
      observer?.outputReceived()
    }
    observer?.outputReceived() // One startup sample; later work is output-driven.
  }

  /// Terminates the running terminal process, if any.
  func stopIfRunning()
  {
    guard processStarted
    else { return }

    directoryObserver?.stop()
    directoryObserver = nil
    directoryGeneration += 1
    terminalView.setProcessOutputHandler(nil)
    terminalView.terminate()
    processStarted = false
    ownedProcessIdentity = nil
  }

  /// Permanent window close releases SwiftTerm's PTY/reaper ownership too.
  /// terminate() alone only sends SIGTERM, which an interactive shell may ignore.
  func finishSessionForClose()
  {
    guard !sessionClosed else { return }
    sessionClosed = true
    geometryReady = nil
    directoryChanged = nil
    sessionStateChanged = nil
    stopIfRunning()
    terminalView?.processDelegate = nil
    terminalView?.geometryDidSettle = nil
    terminalView?.removeFromSuperview()
    terminalView = nil
  }

  /// Restarts the terminal with a new coding agent.
  func restart(with agent: CodingAgent)
  {
    guard self.agent != agent
    else { return }
    self.agent = agent
    workingDirectory = restartDirectory
    stopIfRunning()
    startIfNeeded()
  }

  private func buildLaunchCommand() -> String
  {
    let cd = "cd \(shellEscaped(workingDirectory))"
    let shellExec = "exec \(shellEscaped(shell)) -l -i"

    guard let command = agent.launchCommand
    else {
      return "\(cd) && \(shellExec)"
    }
    return "\(cd) && \(shellExec) -c \(shellEscaped(relaunchScript(command)))"
  }

  private func relaunchScript(_ command: String) -> String
  {
    return """
      while true; do
        \(command)
        exitStatus=$?
        if [ "$exitStatus" -eq 126 ] || [ "$exitStatus" -eq 127 ]; then
          printf '\\n%s exited with status %s. Leaving shell open.\\n' \
            \(shellEscaped(agent.displayName)) "$exitStatus"
          break
        fi
        printf '\\n%s exited with status %s. Relaunching in 2 seconds. Press Ctrl-C to stop.\\n' \
          \(shellEscaped(agent.displayName)) "$exitStatus"
        sleep 2 || break
        printf '\\033[H\\033[2J\\033[3J'
      done
      exec \(shellEscaped(shell)) -l -i
      """
  }

  override func viewDidAppear()
  {
    super.viewDidAppear()
    requestGeometrySynchronization(phase: "appeared", force: true)
    focusTerminal()
  }

  override func viewDidLayout()
  {
    super.viewDidLayout()
    requestGeometrySynchronization(phase: "layout")
  }

  /// Transfers keyboard focus to the terminal view.
  func focusTerminal()
  {
    view.window?.makeFirstResponder(terminalView)
  }

  // MARK: - Private

  /// Reconcile only on actual host layout/attachment/activation events. No
  /// idle timer, synthetic one-pixel resize or resize(cols:) soft reset.
  func requestGeometrySynchronization(phase: String, force: Bool = false)
  {
    guard !sessionClosed, isViewLoaded, !synchronizingGeometry else { return }
    geometryPhase = phase
    geometryForcePending = geometryForcePending || force
    guard !geometryScheduled else { return }
    geometryScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.geometryScheduled = false
      let force = self.geometryForcePending
      self.geometryForcePending = false
      if self.synchronizeGeometry(phase: self.geometryPhase, force: force),
         !self.processStarted { self.geometryReady?() }
    }
  }

  @discardableResult
  private func synchronizeGeometry(phase: String, force: Bool) -> Bool
  {
    guard !synchronizingGeometry, isViewLoaded, let terminal = terminalView,
          let window = terminal.window, terminal.frame.width > 0,
          terminal.frame.height > 0, !terminal.inLiveResize else { return false }
    let signature = "\(ObjectIdentifier(window)) \(view.bounds) \(terminal.frame) \(terminal.bounds) \(window.backingScaleFactor) \(terminal.font.pointSize)"
    guard force || signature != lastGeometrySignature else { return true }
    synchronizingGeometry = true
    defer { synchronizingGeometry = false }
    // SwiftTerm's public native frame-size path computes exact cell geometry
    // and notifies LocalProcessTerminalView. Same-size replay also repairs a
    // stale grid after attachment, without changing the host pane or output.
    terminal.setFrameSize(terminal.frame.size)
    lastGeometrySignature = signature
    synchronizeProcessSize(phase: phase)
    return terminal.terminalDimensions.cols > 0 && terminal.terminalDimensions.rows > 0
  }

  private func actualProcessSize() -> HelmTerminalSize?
  {
    guard let process = terminalView?.process, let expected = ownedProcessIdentity else { return nil }
    let pid = process.shellPid
    let descriptor = process.childfd
    var before = HelmProcessIdentity(), after = HelmProcessIdentity()
    var size = HelmTerminalSize()
    guard pid > 0, descriptor >= 0, HelmOwnedProcessIdentity(pid, &before),
          before.seconds == expected.seconds, before.microseconds == expected.microseconds,
          HelmReadTerminalSize(descriptor, &size),
          process.shellPid == pid, process.childfd == descriptor,
          HelmOwnedProcessIdentity(pid, &after),
          after.seconds == before.seconds, after.microseconds == before.microseconds else { return nil }
    return size
  }

  private func synchronizeProcessSize(phase: String)
  {
    guard let terminal = terminalView else { return }
    let before = actualProcessSize()
    var desired = terminal.getWindowSize() // Renderer geometry, not a PTY read.
    var applied: Bool? = nil
    if let process = terminal.process, process.shellPid > 0,
       before == nil || before?.columns != desired.ws_col ||
       before?.rows != desired.ws_row || before?.pixelWidth != desired.ws_xpixel ||
       before?.pixelHeight != desired.ws_ypixel {
      // Public API holds the LocalProcess session lock while applying ioctl.
      applied = process.updateWindowSize(&desired)
    }
    let after = actualProcessSize()
    let grid = terminal.terminalDimensions
    let optimal = terminal.getOptimalFrameSize()
    let cellWidth = grid.cols > 0 ? optimal.width / CGFloat(grid.cols) : 0
    let cellHeight = grid.rows > 0 ? optimal.height / CGFloat(grid.rows) : 0
    let actual = after.map { "\($0.columns)x\($0.rows) px=\($0.pixelWidth)x\($0.pixelHeight)" } ?? "unavailable"
    let snapshot = "host=\(view.bounds) terminalFrame=\(terminal.frame) terminalBounds=\(terminal.bounds) scale=\(terminal.window?.backingScaleFactor ?? 1) font=\(terminal.font.pointSize) cellPoints=\(cellWidth)x\(cellHeight) grid=\(grid.cols)x\(grid.rows) desiredPTY=\(desired.ws_col)x\(desired.ws_row) actualPTY=\(actual) process=\(terminal.process?.shellPid ?? 0) applied=\(String(describing: applied))"
    guard snapshot != lastSizingDiagnostic else { return }
    lastSizingDiagnostic = snapshot
    repoLogger.notice("terminalSizing \(phase, privacy: .public) \(snapshot, privacy: .public)")
  }

  private func shellEscaped(_ path: String) -> String
  {
    let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
  }

}

// MARK: - Container

/// NSView that fills its background with the terminal background color,
/// automatically adapting to Dark/Light mode changes.
private final class TerminalBackground: NSView
{
  override func draw(_ dirtyRect: NSRect)
  {
    NSColor.textBackgroundColor.setFill()
    dirtyRect.fill()
  }
}

// OSC 7 is emitted by shell integration, not by ordinary `cd` itself.
extension TerminalViewController: LocalProcessTerminalViewDelegate
{
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?)
  {
    // Remote OSC 7 URLs must never select a local directory.
    reportedDirectory = RepositorySession.localTerminalDirectory(directory)
    if reportedDirectory != nil {
      // OSC7 can describe a nested/remote shell more precisely than its parent.
      // Once valid integration is present, do not overwrite it with parent CWD.
      hasOSC7Directory = true
      directoryObserver?.stop()
    }
    directoryChanged?(reportedDirectory)
  }

  func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int)
  {
    requestGeometrySynchronization(phase: "gridChanged", force: true)
  }
  func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
  func processTerminated(source: TerminalView, exitCode: Int32?)
  {
    directoryObserver?.stop()
    directoryObserver = nil
    directoryGeneration += 1
    terminalView.setProcessOutputHandler(nil)
    sessionStateChanged?()
  }
}


/// Public NSView lifecycle notification only; all fitting stays in SwiftTerm's
/// native setFrameSize path and its documented LocalProcess sizing API.
private final class HelmProcessTerminalView: LocalProcessTerminalView
{
  var geometryDidSettle: (() -> Void)?

  override func viewDidMoveToWindow()
  {
    super.viewDidMoveToWindow()
    if window != nil { geometryDidSettle?() }
  }

  override func viewDidEndLiveResize()
  {
    super.viewDidEndLiveResize()
    geometryDidSettle?()
  }
}
