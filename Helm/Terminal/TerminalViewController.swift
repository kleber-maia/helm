import AppKit
import SwiftTerm

/// A self-contained terminal emulator view controller backed by SwiftTerm.
/// Embed as a child view controller to use in any panel, window, or tab.
final class TerminalViewController: NSViewController
{
  private var terminalView: LocalProcessTerminalView!

  /// The working directory the shell starts in.
  let workingDirectory: String

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
    let terminal = LocalProcessTerminalView(frame: .zero)
    let terminalFont = NSFont.monospacedSystemFont(ofSize: 13,
                                                   weight: .regular)

    terminal.font = terminalFont
    terminal.nativeForegroundColor = .textColor
    terminal.nativeBackgroundColor = .textBackgroundColor
    terminal.caretColor = .controlAccentColor
    terminal.translatesAutoresizingMaskIntoConstraints = false
    terminalView = terminal

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

  private var processStarted = false

  /// Starts the terminal process if it has not already been started.
  func startIfNeeded()
  {
    guard !processStarted
    else { return }

    processStarted = true
    let launch = buildLaunchCommand()
    terminalView.startProcess(executable: shell, args: ["-c", launch],
                              environment: nil, execName: nil)
  }

  /// Terminates the running terminal process, if any.
  func stopIfRunning()
  {
    guard processStarted
    else { return }

    terminalView.terminate()
    processStarted = false
  }

  /// Restarts the terminal with a new coding agent.
  func restart(with agent: CodingAgent)
  {
    guard self.agent != agent
    else { return }
    self.agent = agent
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
    focusTerminal()
  }

  override func viewDidLayout()
  {
    super.viewDidLayout()
    applyOverlayScroller()
  }

  /// Transfers keyboard focus to the terminal view.
  func focusTerminal()
  {
    view.window?.makeFirstResponder(terminalView)
  }

  // MARK: - Private

  private var scrollerPatched = false

  private func applyOverlayScroller()
  {
    guard !scrollerPatched,
          let scroller = terminalView.subviews.first(where: { $0 is NSScroller }) as? NSScroller
    else { return }
    scroller.scrollerStyle = .overlay
    scrollerPatched = true
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
