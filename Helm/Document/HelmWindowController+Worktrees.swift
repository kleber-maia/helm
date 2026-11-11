import AppKit

extension HelmWindowController: WorktreeTerminalHost
{
  var terminalForTransfer: TerminalPanelViewController { terminalPanelController! }
  var terminalIsRunning: Bool {
    terminalPanelController?.terminalController.hasRunningProcess == true
  }
  var transferIsBlocked: Bool {
    currentOperation != nil || repoDocument?.worktreeRemovalPending == true ||
    repoDocument?.closeDecisionPending == true ||
    repoDocument?.closeApproved == true ||
    (NSDocumentController.shared as? HelmDocumentController)?.worktrees.isConfirmingTermination == true ||
    terminalPanelController == nil || splitViewController == nil
  }

  func replaceTerminalForTransfer(_ terminal: TerminalPanelViewController)
  {
    let old = terminalPanelController!
    old.prepareForAdoption()
    terminal.prepareForAdoption()
    if let item = splitViewController.splitViewItems.first(where: {
      $0.viewController === old
    }) {
      splitViewController.removeSplitViewItem(item)
    }
    old.removeFromParent()
    terminal.removeFromParent()
    let item = NSSplitViewItem(viewController: terminal)
    item.canCollapse = true
    item.minimumThickness = 240
    item.preferredThicknessFraction = 0.4
    item.isCollapsed = false
    item.holdingPriority = .init(450)
    splitViewController.addSplitViewItem(item)
    terminalPanelController = terminal
    terminal.didAdopt()
    bindTerminalDirectoryObserver()
  }

  func bindTerminalDirectoryObserver()
  {
    if let bound = repoDocument?.worktreeBinding?.record.path {
      terminalPanelController?.terminalController.bindWorkingDirectory(bound)
    }
    terminalPanelController?.terminalController.sessionStateChanged = {
      [weak self] in
      guard let document = self?.repoDocument else { return }
      (NSDocumentController.shared as? HelmDocumentController)?.worktrees.retryPending(document)
    }
    terminalPanelController?.terminalController.directoryChanged = {
      [weak self] directory in
      guard let document = self?.repoDocument else { return }
      (NSDocumentController.shared as? HelmDocumentController)?
        .worktrees.directoryChanged(directory, in: document)
    }
  }

  func makeWorktreesToolbarItem() -> NSToolbarItem
  {
    let item = NSToolbarItem(itemIdentifier: .worktrees)
    item.label = "Worktrees"
    item.paletteLabel = "Worktrees"
    item.isBordered = false // The native button owns its pill; the badge sits outside it.
    let menu = NSMenu(title: "Worktrees")
    menu.autoenablesItems = false
    menu.delegate = self
    let title = NSMenuItem(title: "Worktrees", action: nil, keyEquivalent: "")
    title.isHidden = true // Reserve the pull-down title, never the Primary entry.
    menu.addItem(title)
    item.view = WorktreeToolbarControl(menu: menu)
    let overflow = NSMenuItem(title: "Worktrees", action: nil, keyEquivalent: "")
    overflow.submenu = menu
    item.menuFormRepresentation = overflow
    worktreesMenu = menu
    updateWorktreesToolbarItem(item)
    return item
  }

  private func updateWorktreesToolbarItem(_ item: NSToolbarItem)
  {
    guard let control = item.view as? WorktreeToolbarControl else { return }
    guard let common = repoDocument?.worktreeBinding?.record.repositoryID,
          let workspace = (NSDocumentController.shared as? HelmDocumentController)?.worktrees,
          let count = workspace.existingWorktreeCount(for: common) else {
      control.update(count: nil, color: .secondaryLabelColor)
      item.toolTip = control.toolTip
      return
    }
    control.update(count: count, color: workspace.color(for: common))
    item.toolTip = control.toolTip
  }

  private func refreshWorktreesToolbarImage()
  {
    if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == .worktrees }) {
      updateWorktreesToolbarItem(item)
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu)
  {
    guard menu === worktreesMenu, let document = repoDocument else { return }
    (NSDocumentController.shared as? HelmDocumentController)?
      .worktrees.populate(menu, for: document)
    refreshWorktreesToolbarImage()
  }

  func refreshWorktreePresentation()
  {
    refreshWorktreesToolbarImage()
    guard let binding = repoDocument?.worktreeBinding,
          let workspace = (NSDocumentController.shared as? HelmDocumentController)?
            .worktrees, let window else { return }
    let accessory = worktreeAccessory ?? WorktreeTabAccessory()
    worktreeAccessory = accessory
    let role = binding.isPinnedPrimary ? "Primary checkout" :
        (binding.additionalSession ? "Additional terminal session" : "Linked worktree")
    let repoName = URL(fileURLWithPath: binding.record.repositoryID)
      .deletingLastPathComponent().lastPathComponent
    accessory.setRepository(color: workspace.color(for: binding.record.repositoryID),
        primary: binding.isPinnedPrimary, label: "\(repoName), \(role)")
    window.tab.accessoryView = accessory
    window.tab.toolTip = "\(repoName) — \(role)\n\(binding.record.path)"
    updateMiniwindowTitle()
  }
}

final class WorktreeTabAccessory: NSStackView
{
  private let badge = NSImageView()
  private let counts = WorkspaceStatusIndicator()

  init()
  {
    super.init(frame: .zero)
    orientation = .horizontal
    alignment = .centerY
    spacing = 3
    addArrangedSubview(badge)
    addArrangedSubview(counts)
    badge.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      badge.widthAnchor.constraint(equalToConstant: 13),
      badge.heightAnchor.constraint(equalToConstant: 13),
    ])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

  func setRepository(color: NSColor, primary: Bool, label: String)
  {
    badge.image = NSImage(systemSymbolName: primary ? "house.fill" : "circle.fill",
                          accessibilityDescription: label)
    badge.contentTintColor = color
    badge.setAccessibilityLabel(label)
    badge.toolTip = label
  }
  func setStatus(staged: Int, unstaged: Int, enabled: Bool)
  {
    counts.setStatus(unstaged: unstaged, staged: staged)
    counts.isHidden = !enabled || (staged == 0 && unstaged == 0)
  }
}

/// Native pull-down behavior, with a public count capsule because NSItemBadge
/// has no color API. No private toolbar subviews or fixed item widths.
final class WorktreeToolbarControl: NSView
{
  private let button: NSPopUpButton
  private let badge = WorktreeCountBadge()
  private let bezel = NSGlassEffectView()
  private let nativeSizeReference: NSButton
  private var envelopeHeight: NSLayoutConstraint!
  private var verticalClearance: CGFloat { ceil(badge.intrinsicContentSize.height / 2) + 2 }

  override var alignmentRectInsets: NSEdgeInsets {
    NSEdgeInsets(top: verticalClearance, left: 0,
                 bottom: verticalClearance, right: 0)
  }

  private var fullButtonSize: NSSize {
    let content = button.intrinsicContentSize
    // An unbordered pull-down reports only its content height. Measure the
    // platform's full glass action-button height instead of shrinking the
    // button to make room for an outside count.
    return NSSize(width: content.width,
                  height: max(content.height, nativeSizeReference.intrinsicContentSize.height))
  }

  init(menu: NSMenu)
  {
    button = NSPopUpButton(image: HelmToolbarAppearance.symbol("rectangle.stack",
        description: "Worktrees")!, pullDownMenu: menu)
    nativeSizeReference = NSButton(image: HelmToolbarAppearance.symbol("rectangle.stack",
        description: "Worktrees")!, target: nil, action: nil)
    nativeSizeReference.bezelStyle = .glass
    nativeSizeReference.controlSize = .large
    nativeSizeReference.isBordered = true
    nativeSizeReference.imagePosition = .imageOnly
    super.init(frame: .zero)
    menu.items.first?.isHidden = true
    button.usesItemFromMenu = false
    button.autoenablesItems = false
    button.bezelStyle = .texturedRounded
    button.isBordered = false
    button.controlSize = .large
    button.imagePosition = .imageOnly
    button.setAccessibilityIdentifier("helm.worktrees")
    bezel.style = .regular
    bezel.contentView = button
    if #available(macOS 27.0, *) { bezel.effectIsInteractive = true }
    addSubview(bezel)
    addSubview(badge)
    // Reserve the whole overlay footprint, while keeping the badge outside
    // the button's native bezel. No private toolbar subviews are involved.
    translatesAutoresizingMaskIntoConstraints = false
    envelopeHeight = heightAnchor.constraint(equalToConstant: intrinsicContentSize.height)
    envelopeHeight.isActive = true
    setContentCompressionResistancePriority(.required, for: .vertical)
    setContentCompressionResistancePriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    badge.setContentCompressionResistancePriority(.required, for: .horizontal)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
  override var intrinsicContentSize: NSSize {
    let size = fullButtonSize
    let extra = badge.isHidden ? NSSize.zero : badge.intrinsicContentSize
    return NSSize(width: size.width + (badge.isHidden ? 0 : ceil(extra.width / 2) + 2),
                  height: size.height)
  }
  override func layout()
  {
    super.layout()
    let size = fullButtonSize
    bezel.frame = NSRect(x: 0, y: verticalClearance, width: size.width, height: size.height)
    bezel.cornerRadius = size.height / 2
    button.frame = bezel.bounds
    let countSize = badge.intrinsicContentSize
    badge.frame = NSRect(x: bezel.frame.maxX - countSize.width / 2,
                         y: bezel.frame.maxY - countSize.height / 2,
                         width: countSize.width, height: countSize.height)

  }
  override func mouseDown(with event: NSEvent)
  {
    // The count/gap is part of the same menu hit target.
    button.performClick(self)
  }
  func update(count: Int?, color: NSColor)
  {
    (button.cell as? NSPopUpButtonCell)?.menuItem?.image =
        HelmToolbarAppearance.symbol("rectangle.stack", description: "Worktrees")
    badge.count = count ?? 0
    badge.color = color
    badge.isHidden = (count ?? 0) < 1
    badge.invalidateIntrinsicContentSize()
    envelopeHeight.constant = intrinsicContentSize.height
    invalidateIntrinsicContentSize()
    needsLayout = true
    badge.needsDisplay = true
    let description: String
    if let count {
      description = "\(count) linked \(count == 1 ? "worktree" : "worktrees"); primary excluded. Locked/unavailable registrations included."
    }
    else { description = "Worktree count unavailable — open the menu to retry Git inventory" }
    toolTip = description
    button.toolTip = description
    button.setAccessibilityLabel("Worktrees, " + description)
  }
}

private final class WorktreeCountBadge: NSView
{
  var count = 0
  var color = NSColor.controlAccentColor
  private let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
  override var intrinsicContentSize: NSSize {
    NSSize(width: max(14, ceil((String(count) as NSString).size(withAttributes: [.font: font]).width) + 6), height: 14)
  }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect)
  {
    color.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    let attributes: [NSAttributedString.Key: Any] = [.font: font,
        .foregroundColor: color.contrastingTextColor]
    let text = String(count) as NSString
    let size = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                         y: (bounds.height - size.height) / 2), withAttributes: attributes)
  }
}
