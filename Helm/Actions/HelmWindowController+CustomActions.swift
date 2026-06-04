import AppKit

extension HelmWindowController
{
  var repoPath: String
  { repository.repoURL.path }

  @objc
  func runDefaultAction(_ sender: Any?)
  {
    let actions = CustomActionsStore.actions(for: repoPath)

    guard let first = actions.first
    else {
      configureActions(sender)
      return
    }

    CustomActionRunner.run(first,
                           in: repoPath,
                           window: window)
  }

  @objc
  func runCustomAction(_ sender: NSMenuItem)
  {
    let actions = CustomActionsStore.actions(for: repoPath)
    let index = sender.tag

    guard actions.indices.contains(index)
    else { return }

    CustomActionRunner.run(actions[index],
                           in: repoPath,
                           window: window)
  }

  @objc
  func configureActions(_ sender: Any?)
  {
    guard let window
    else { return }

    let actions = CustomActionsStore.actions(for: repoPath)
    let dialog = CustomActionsDialog(actions: actions)

    Task {
      guard let model = await dialog.getOptions(
          parent: window)
      else { return }

      CustomActionsStore.save(model.actions,
                              for: repoPath)
      titleBarController?.updateCustomActionButton(
          repoPath: repoPath)
    }
  }
}
