import AppKit

/// NSSplitViewController subclass for the main window split.
/// Equalizes the two panes on either side of a divider when it is
/// double-clicked, except for the sidebar divider which keeps its default
/// show/hide behavior.
final class MainSplitController: NSSplitViewController
{
  var contentLayoutDidChange: (() -> Void)?
  private var sidebarVisibility: NSKeyValueObservation?
  private var sidebarPinned = true
  var sidebarIsPinned: Bool { sidebarPinned }

  func restoreSidebarHidden(_ hidden: Bool)
  {
    if sidebarPinned == hidden { toggleSidebar(nil) }
  }
  private var changingSidebarPin = false

  /// Called once for the new item before the window is shown. A later native
  /// temporary uncollapse must never be interpreted as an explicit pin.
  func configureSidebarPolicy()
  {
    guard let sidebar = splitViewItems.first else { return }
    sidebarPinned = !sidebar.isCollapsed
    sidebarVisibility = sidebar.observe(\.isCollapsed, options: [.new]) {
      [weak self] item, _ in
      guard let self, !self.changingSidebarPin else { return }
      if item.isCollapsed { self.sidebarPinned = false }
      self.updateSidebarOverlayPolicy()
    }
    updateSidebarOverlayPolicy()
  }

  override func viewDidLayout()
  {
    super.viewDidLayout()
    defer { contentLayoutDidChange?() }
    guard sidebarVisibility != nil, !changingSidebarPin else { return }
    updateSidebarOverlayPolicy()
  }

  private func updateSidebarOverlayPolicy()
  {
    guard let sidebar = splitViewItems.first, !changingSidebarPin else { return }
    let threshold: CGFloat = sidebarPinned ? 0 : splitView.bounds.width + 1

    // Hidden intent stays below the inline threshold at the CURRENT width;
    // AppKit owns the edge-hover reveal and its overlay/dismiss animation.
    if minimumThicknessForInlineSidebars != threshold {
      minimumThicknessForInlineSidebars = threshold
    }
    if sidebar.canCollapseFromWindowResize != !sidebarPinned {
      sidebar.canCollapseFromWindowResize = !sidebarPinned
    }
    for item in splitViewItems.dropFirst() {
      if item.automaticallyAdjustsSafeAreaInsets != !sidebarPinned {
        item.automaticallyAdjustsSafeAreaInsets = !sidebarPinned
      }
    }
  }

  override func viewDidAppear()
  {
    super.viewDidAppear()
    contentLayoutDidChange?()
  }

  /// Explicit toggle pins inline; native temporary reveal retains hidden intent.
  override func toggleSidebar(_ sender: Any?)
  {
    guard let sidebar = splitViewItems.first else { return }
    let pin = !sidebarPinned || sidebar.isCollapsed

    changingSidebarPin = true
    sidebarPinned = pin
    // Perform explicit collapse/expansion with the known pinned geometry first.
    minimumThicknessForInlineSidebars = 0
    sidebar.canCollapseFromWindowResize = false
    for item in splitViewItems.dropFirst() {
      item.automaticallyAdjustsSafeAreaInsets = false
    }
    sidebar.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
    sidebar.isCollapsed = !pin
    splitView.layoutSubtreeIfNeeded()
    changingSidebarPin = false
    updateSidebarOverlayPolicy()
    splitView.layoutSubtreeIfNeeded()
  }

  override func splitView(
      _ splitView: NSSplitView,
      shouldCollapseSubview subview: NSView,
      forDoubleClickOnDividerAt dividerIndex: Int) -> Bool
  {
    guard dividerIndex > 0
    else { return super.splitView(splitView,
                                  shouldCollapseSubview: subview,
                                  forDoubleClickOnDividerAt: dividerIndex) }

    splitView.equalizeSubviews(atDivider: dividerIndex)
    return false
  }
}
