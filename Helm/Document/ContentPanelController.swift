import Cocoa

/// Container that switches between the history+details split and the
/// standalone review panel, based on whether the Review sidebar item
/// is selected.
final class ContentPanelController: NSViewController
{
    private(set) var historySplitController: HistorySplitController!
    private(set) var reviewViewController: FileViewController!

    override func loadView()
    {
        view = NSView()
    }

    func configure(historySplit: HistorySplitController,
                   review: FileViewController)
    {
        historySplitController = historySplit
        reviewViewController = review

        for child in [historySplit, review] as [NSViewController] {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child.view)
            NSLayoutConstraint.activate([
                child.view.topAnchor.constraint(equalTo: view.topAnchor),
                child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
        review.view.isHidden = true
    }

    /// Switches between the review panel (`true`) and the history+details
    /// split (`false`).
    func showReview(_ show: Bool)
    {
        historySplitController.view.isHidden = show
        reviewViewController.view.isHidden = !show
    }
}
