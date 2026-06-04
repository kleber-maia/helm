import AppKit

/// NSSplitViewController subclass for the main window split.
/// Equalizes the two panes on either side of a divider when it is
/// double-clicked, except for the sidebar divider which keeps its default
/// show/hide behavior.
final class MainSplitController: NSSplitViewController
{
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
