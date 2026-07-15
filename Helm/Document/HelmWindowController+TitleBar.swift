import Cocoa

extension HelmWindowController
{
  func updateNavButtons()
  {
    updateNavControl(titleBarController?.navButtons)
  }

  func updateNavControl(_ control: NSSegmentedControl?)
  {
    guard let control = control
    else { return }

    control.setEnabled(!navBackStack.isEmpty, forSegment: 0)
    control.setEnabled(!navForwardStack.isEmpty, forSegment: 1)
  }

  func configureTitleBarController(
    repository: any BasicRepository & CommitReferencing & Branching)
  {
    let viewController: TitleBarController = titleBarController!

    // This can't be connected in the storyboard because TitleBarDelegate is
    // not objc compatible.
    viewController.delegate = self
    viewController.finishSetup()
    sinks.append(queue.busyPublisher.sinkOnMainQueue {
      [weak viewController] in
      viewController?.progressHidden = !$0
    })
    if let controller = self.repoController {
      viewController.observe(controller: controller)
    }
  }
}

extension HelmWindowController: TitleBarDelegate
{
  func branchSelecetd(_ branch: String)
  {
    guard let branchRef = LocalBranchRefName.named(branch)
    else {
      // show error?
      return
    }

    guard let repository = repoDocument?.repository
    else { return }

    repoController.queue.executeOffMainThread { [weak self] in

      do {
        try repository.checkOut(branch: branchRef)
        Task { @MainActor in
          self?.repoController.refsChanged()
        }
      }
      catch let error as RepoError {
        Task { @MainActor in
          self?.showErrorMessage(error: error)
        }
      }
      catch {
        Task { @MainActor in
          self?.showErrorMessage(error: .unexpected)
        }
      }
    }
  }

  func goBack() { goBack(self) }
  func goForward() { goForward(self) }
  func pushSelected() { push(self) }
  func pullSelected() { pull(self) }
  func stashSelected() { stash(self) }
  func popStashSelected() { popStash(self) }
  func applyStashSelected() { applyStash(self) }
  func dropStashSelected() { dropStash(self) }
  func search(for text: String,
              type: HistorySearchType,
              direction: SearchDirection)
  {
    historyController.search(for: text, type: type, direction: direction)
  }
}

extension HelmWindowController
{
  @IBAction
  func performFindPanelAction(_ sender: Any?)
  {
    let tag = UInt((sender as? NSMenuItem)?.tag ?? 0)

    guard let action = NSFindPanelAction(rawValue: tag)
    else { return }

    switch action {
      case .showFindPanel:
        titleBarController?.showSearch()
      case .next:
        titleBarController?.search(.down)
      case .previous:
        titleBarController?.search(.up)
      case .setFindString:
        selectedFindString().map { titleBarController?.useSelectionForSearch($0) }
      default:
        break
    }
  }

  func selectedFindString() -> String?
  {
    guard let textView = window?.firstResponder as? NSTextView
    else { return nil }
    let selection = textView.selectedRange()

    guard selection.length > 0
    else { return nil }
    return (textView.string as NSString).substring(with: selection)
  }
}
