import AppKit
import SwiftUI

/// A failed/stale save leaves this same editor and all unsaved edits open.
struct CustomActionsDialog
{
  let snapshot: ActionsSnapshot
  let repoPath: String

  @MainActor
  func edit(parent: NSWindow) async -> Bool
  {
    let model = CustomActionsModel(actions: snapshot.actions)
    model.storageNotice = "Shared by this repository's worktrees and Helm builds. Every save keeps a verified private backup."
    if snapshot.pendingConflicts > 0 {
      model.storageNotice += " \(snapshot.pendingConflicts) other saved set(s) await recovery review."
    }
    let sheet = NSWindow()
    let root = SheetDialogView<CustomActionsPanel>(model: model,
      acceptButtonTitle: UIString(rawValue: "Save Actions"),
      cancel: { parent.endSheet(sheet, returnCode: .cancel) },
      accept: {
        do {
          _ = try CustomActionsStore.save(model.actions, for: repoPath,
                                          expectedRevision: snapshot.revision)
          parent.endSheet(sheet, returnCode: .OK)
        }
        catch { model.storageError = error.localizedDescription }
      })
    let host = NSHostingController(rootView: root)
    sheet.contentViewController = host
    host.view.layoutSubtreeIfNeeded()
    sheet.setContentSize(host.view.fittingSize)
    return await parent.beginSheet(sheet) == .OK
  }
}
