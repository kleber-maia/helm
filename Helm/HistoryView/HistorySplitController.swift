import Cocoa

final class HistorySplitController: NSSplitViewController
{
  weak var historyController: HistoryViewController!

  var historyHidden: Bool { splitViewItems[0].isCollapsed }
  var detailsHidden: Bool { splitViewItems[1].isCollapsed }

  override func loadView()
  {
    super.loadView()
    splitView.isVertical = false
  }

  override func viewDidLoad()
  {
    super.viewDidLoad()
    historyController = splitViewItems[0].viewController as? HistoryViewController
    historyController.splitController = self

    let fileController = FileViewController(nibName: .fileViewControllerNib,
                                            bundle: nil)
    let fileViewItem = NSSplitViewItem(viewController: fileController)

    historyController.fileViewController = fileController
    fileViewItem.canCollapse = true
    fileViewItem.minimumThickness = FileViewController.minDetailHeight +
                                    FileViewController.minHeaderHeight
    fileViewItem.holdingPriority = .defaultLow
    fileViewItem.preferredThicknessFraction = 0.5
    insertSplitViewItem(fileViewItem, at: 1)

    splitViewItems[0].canCollapse = true
    splitViewItems[0].minimumThickness = 60
    splitViewItems[0].preferredThicknessFraction = 0.5

    splitView.dividerStyle = .thick
  }

  override func viewDidAppear()
  {
    super.viewDidAppear()
    let bounds = splitView.bounds
    guard bounds.height > 0,
          splitView.subviews.count > 1
    else { return }
    splitView.setPosition(bounds.height * 0.5, ofDividerAt: 0)
  }

  override func splitView(
      _ splitView: NSSplitView,
      shouldCollapseSubview subview: NSView,
      forDoubleClickOnDividerAt dividerIndex: Int) -> Bool
  {
    splitView.equalizeSubviews(atDivider: dividerIndex)
    return false
  }

  @IBAction
  func toggleHistory(_: Any?)
  {
    if splitViewItems[0].isCollapsed {
      splitViewItems[0].isCollapsed = false
    }
    else {
      if splitViewItems[1].isCollapsed {
        splitViewItems[1].isCollapsed = false
      }
      splitViewItems[0].isCollapsed = true
    }
  }

  @IBAction
  func toggleDetails(_: Any?)
  {
    if splitViewItems[1].isCollapsed {
      splitViewItems[1].isCollapsed = false
    }
    else {
      if splitViewItems[0].isCollapsed {
        splitViewItems[0].isCollapsed = false
      }
      splitViewItems[1].isCollapsed = true
    }
  }
}
