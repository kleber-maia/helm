import AppKit

extension HelmWindowController
{
  var repoPath: String
  { repository.repoURL.path }

  @objc
  func runDefaultAction(_ sender: Any?)
  {
    guard !worktreeTransitionPending else {
      showErrorMessage(error: .worktreeContextMismatch)
      return
    }
    guard let snapshot = loadActionsOrReport() else { return }
    let actions = snapshot.actions

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
    guard !worktreeTransitionPending else {
      showErrorMessage(error: .worktreeContextMismatch)
      return
    }
    guard let snapshot = loadActionsOrReport() else { return }
    let actions = snapshot.actions
    guard let id = sender.representedObject as? UUID,
          let action = actions.first(where: { $0.id == id }) else { return }

    CustomActionRunner.run(action,
                           in: repoPath,
                           window: window)
  }

  @objc
  func configureActions(_ sender: Any?)
  {
    guard let window
    else { return }

    guard let snapshot = loadActionsOrReport() else { return }
    let dialog = CustomActionsDialog(snapshot: snapshot, repoPath: repoPath)
    Task {
      if await dialog.edit(parent: window) { refreshActionsPresentation() }
    }
  }

  private func refreshActionsPresentation()
  {
    for document in NSDocumentController.shared.documents.compactMap({ $0 as? RepoDocument }) {
      document.windowController?.titleBarController?.updateCustomActionButton(
          repoPath: document.repository.repoURL.path)
    }
  }

  private func loadActionsOrReport() -> ActionsSnapshot?
  {
    do { return try CustomActionsStore.load(for: repoPath) }
    catch {
      let alert = NSAlert()
      alert.messageText = "Actions could not be loaded"
      alert.informativeText = error.localizedDescription + " Your original data was not cleared. An empty editor will not be saved over it."
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Recover Saved Actions…")
      if let window {
        alert.beginSheetModal(for: window) { [weak self] result in
          if result == .alertSecondButtonReturn { self?.recoverSavedActions(nil) }
        }
      }
      return nil
    }
  }

  @objc func recoverSavedActions(_ sender: Any?)
  {
    guard let window else { return }
    do {
      let recovery = try CustomActionsStore.recovery(for: repoPath)
      let alert = NSAlert()
      alert.messageText = "Resolve Older Actions"
      alert.informativeText = "An older copy differs from the current repository Actions. Keep the current set or use the selected older set. Original IDs, order and configuration are retained; BOTH are backed up and no original preference key is deleted. Private backups: \(recovery.backups.path)"
      let chooser = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 480, height: 28), pullsDown: false)
      for choice in recovery.choices {
        chooser.addItem(withTitle: "\(choice.actions.count) Actions — \(choice.label)")
      }
      alert.accessoryView = chooser
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Use Saved Set")
      alert.addButton(withTitle: "Keep Current Set")
      alert.buttons[1].isEnabled = !recovery.choices.isEmpty
      alert.beginSheetModal(for: window) { [weak self] result in
        guard let self else { return }
        guard result == .alertSecondButtonReturn || result == .alertThirdButtonReturn,
              recovery.choices.indices.contains(chooser.indexOfSelectedItem) else { return }
        do {
          _ = try CustomActionsStore.recover(recovery.choices[chooser.indexOfSelectedItem],
              for: self.repoPath, expectedRevision: recovery.revision,
              keepCurrent: result == .alertThirdButtonReturn)
          self.refreshActionsPresentation()
        }
        catch { self.showActionsStorageError(error) }
      }
    }
    catch { showActionsStorageError(error) }
  }

  private func showActionsStorageError(_ error: Error)
  {
    let alert = NSAlert()
    alert.messageText = "Actions were not replaced"
    alert.informativeText = error.localizedDescription
    if let window { alert.beginSheetModal(for: window) }
  }
}
