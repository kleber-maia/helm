import AppKit

/// Hosts a TerminalViewController inside the main window's split view.
/// For other embedding contexts, use TerminalViewController directly.
final class TerminalPanelViewController: NSViewController
{
  private(set) var terminalController: TerminalViewController
  private var collapseObserver: NSKeyValueObservation?
  private var startTimer: Timer?
  private var isWindowMain = false

  init(workingDirectory: String, agent: CodingAgent = .terminal)
  {
    self.terminalController = TerminalViewController(workingDirectory: workingDirectory,
                                                     agent: agent)
    super.init(nibName: nil, bundle: nil)
  }

  @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

  override func loadView()
  {
    view = NSView()
  }

  override func viewDidLoad()
  {
    super.viewDidLoad()
    addChild(terminalController)
    terminalController.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(terminalController.view)
    NSLayoutConstraint.activate([
      terminalController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      terminalController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      terminalController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      terminalController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    observeCollapseState()
  }

  override func viewDidAppear()
  {
    super.viewDidAppear()
    if view.window?.isMainWindow == true {
      isWindowMain = true
    }
    startIfVisible()
  }

  /// Called by HelmWindowController when the terminal panel is expanded.
  func becomeTerminalFirstResponder()
  {
    terminalController.focusTerminal()
  }

  /// Called by HelmWindowController when this window becomes the main window.
  func windowDidBecomeMain()
  {
    isWindowMain = true
    startIfVisible()
  }

  /// Called by HelmWindowController when this window resigns main.
  func windowDidResignMain()
  {
    isWindowMain = false
    startTimer?.invalidate()
    startTimer = nil
  }

  /// Restarts the terminal with a new coding agent by replacing the
  /// underlying controller, avoiding state issues from reusing the
  /// same `LocalProcess` instance.
  func restart(with agent: CodingAgent)
  {
    terminalController.view.removeFromSuperview()
    terminalController.removeFromParent()

    let newController = TerminalViewController(
        workingDirectory: terminalController.workingDirectory,
        agent: agent,
        shell: terminalController.shell)
    terminalController = newController

    addChild(newController)
    newController.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(newController.view)
    NSLayoutConstraint.activate([
      newController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      newController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      newController.view.topAnchor.constraint(
          equalTo: view.safeAreaLayoutGuide.topAnchor),
      newController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    startIfVisible()
  }

  // MARK: - Private

  private func observeCollapseState()
  {
    guard let splitViewController = parent as? NSSplitViewController
    else { return }

    guard let item = splitViewController.splitViewItem(for: self)
    else { return }

    updateTerminalRunning(collapsed: item.isCollapsed)

    collapseObserver = item.observe(\.isCollapsed, options: [.new]) {
      [weak self] item, _ in
      self?.updateTerminalRunning(collapsed: item.isCollapsed)
    }
  }

  private static let startDelay: TimeInterval = 1.0

  private func updateTerminalRunning(collapsed: Bool)
  {
    if collapsed {
      startTimer?.invalidate()
      startTimer = nil
      terminalController.stopIfRunning()
    }
    else if isWindowMain {
      guard startTimer == nil
      else { return }

      startTimer = Timer.scheduledTimer(withTimeInterval: Self.startDelay,
                                        repeats: false) {
        [weak self] _ in
        self?.startTimer = nil
        guard let self,
              self.isWindowMain,
              let splitViewController = self.parent as? NSSplitViewController,
              let item = splitViewController.splitViewItem(for: self),
              !item.isCollapsed
        else { return }
        self.terminalController.startIfNeeded()
      }
    }
    else {
      startTimer?.invalidate()
      startTimer = nil
    }
  }

  private func startIfVisible()
  {
    guard let splitViewController = parent as? NSSplitViewController
    else { return }

    guard let item = splitViewController.splitViewItem(for: self)
    else { return }

    updateTerminalRunning(collapsed: item.isCollapsed)
  }
}
