import Cocoa

extension FileViewController: NSSplitViewDelegate
{
  static let minHeaderHeight: CGFloat = 45
  static let minDetailHeight: CGFloat = 60
  static let defaultFileListWidth: CGFloat = 305

  /// Sets the file-list split position once the view has valid bounds.
  /// The delegate's `shouldAdjustSizeOfSubview` already keeps the file
  /// list at a fixed width during subsequent window resizes.
  func applyFileListPosition()
  {
    guard fileSplitView.bounds.width > 0,
          !fileSplitView.isHiddenOrHasHiddenAncestor
    else { return }

    fileSplitView.setPosition(
        Self.defaultFileListWidth, ofDividerAt: 0)
  }

  // MARK: - NSSplitViewDelegate

  public func splitView(_ splitView: NSSplitView,
                        shouldAdjustSizeOfSubview view: NSView) -> Bool
  {
    switch splitView {
      case fileSplitView:
        return view != fileListTabView
      default:
        return true
    }
  }

  public func splitView(_ splitView: NSSplitView,
                        constrainMinCoordinate proposedMinimumPosition: CGFloat,
                        ofSubviewAt dividerIndex: Int) -> CGFloat
  {
    return proposedMinimumPosition
  }

  public func splitView(_ splitView: NSSplitView,
                        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                        ofSubviewAt dividerIndex: Int) -> CGFloat
  {
    return proposedMaximumPosition
  }
}
