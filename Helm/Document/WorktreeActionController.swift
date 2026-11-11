import AppKit

struct WorktreeRemovalRequest
{
  let owner: UUID
  let record: WorktreeRecord
}

/// A sheet owns no files or branches until its explicit confirmation.
@MainActor
private final class WorktreeCreationForm: NSObject, NSTextFieldDelegate
{
  let alert = NSAlert()
  let branch = NSTextField(string: "")
  let directory: NSTextField
  let validation = NSTextField(wrappingLabelWithString: "")

  init(source: WorktreeRecord)
  {
    directory = NSTextField(string: source.path + "-worktree")
    super.init()
    alert.messageText = "New Worktree"
    alert.informativeText = "Create a new branch from \(source.branch ?? "detached HEAD") at \(source.head?.prefix(7) ?? "unknown"). The existing checkout is unchanged."
    alert.addButton(withTitle: "Create Worktree")
    alert.addButton(withTitle: "Cancel")
    branch.placeholderString = "New branch name"
    branch.setAccessibilityLabel("New branch name")
    directory.setAccessibilityLabel("Worktree directory")
    branch.delegate = self
    directory.delegate = self
    let stack = NSStackView(views: [
      NSTextField(labelWithString: "Branch"), branch,
      NSTextField(labelWithString: "Absolute directory path"), directory,
      validation,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 440, height: 170)
    for field in [branch, directory, validation] {
      field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    validation.textColor = .secondaryLabelColor
    alert.accessoryView = stack
    validate()
  }

  var values: (String, String)? {
    let name = branch.stringValue
    let path = (directory.stringValue as NSString).expandingTildeInPath
    guard !name.isEmpty, !name.hasPrefix("-"),
          GitReference.isValidName("refs/heads/" + name), path.hasPrefix("/"),
          !FileManager.default.fileExists(atPath: path) else { return nil }
    var isDirectory: ObjCBool = false
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory),
          isDirectory.boolValue else { return nil }
    return (name, path)
  }

  func controlTextDidChange(_ notification: Notification) { validate() }
  private func validate()
  {
    let valid = values != nil
    alert.buttons.first?.isEnabled = valid
    validation.stringValue = valid ? "Git will check branch availability before creating the checkout." :
      "Enter a valid new branch and a new directory inside an existing parent folder."
  }
}

/// Uses the document's existing serialized operation lane. No force removal,
/// branch deletion, terminal shutdown or post-failure cleanup is performed.
final class WorktreeActionController: OperationController
{
  enum Action { case create, remove(WorktreeRecord) }
  private let action: Action
  private let source: WorktreeRecord
  private var form: WorktreeCreationForm?
  private var activeAlert: NSAlert?
  private var completed = false
  private var createdDirectory: String?
  var removalBlocker: ((WorktreeRecord) -> String?)?
  var removalConfirmed: ((WorktreeRecord) -> String?)?
  var removalRecheck: ((WorktreeRecord) -> String?)?
  var removalProcessRecheck: (@Sendable () -> String?)?

  func isRemoving(_ id: String) -> Bool
  {
    if case .remove(let record) = action { return record.id == id }
    return false
  }
  var finished: ((OperationResult, String?) -> Void)?

  init(windowController: HelmWindowController, action: Action,
       source: WorktreeRecord)
  {
    self.action = action
    self.source = source
    super.init(windowController: windowController)
  }

  override func start() throws
  {
    guard let window = windowController?.window else {
      ended(result: .canceled)
      return
    }
    switch action {
      case .create:
        let form = WorktreeCreationForm(source: source)
        self.form = form
        activeAlert = form.alert
        form.alert.beginSheetModal(for: window) { [weak self] response in
          guard let self else { return }
          self.activeAlert = nil
          guard response == .alertFirstButtonReturn, !self.canceled,
                let values = self.form?.values else {
            self.ended(result: .canceled)
            return
          }
          self.form = nil
          self.execute(.create(self.source, values.0, values.1))
        }
      case .remove(let record):
        if let message = removalBlocker?(record) {
          showFailureError(message)
          ended(result: .failure)
          return
        }
        let alert = NSAlert()
        alert.messageText = "Remove Worktree?"
        alert.informativeText = "Remove \(record.path)? Its branch will be kept. The worktree must be clean and unlocked. After successful removal, its open tabs and apparently idle plain shells will close. Agents, child jobs and unknown activity are blocked. Process checks cannot prove that a shell builtin is idle: confirm only if these shells are at a prompt. Close other applications using this checkout first. Cancellation or Git failure keeps tabs and shells intact. This does not delete its branch."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove Worktree")
        activeAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
          guard let self else { return }
          self.activeAlert = nil
          guard response == .alertSecondButtonReturn, !self.canceled else {
            self.ended(result: .canceled)
            return
          }
          if let message = self.removalConfirmed?(record) {
            self.showFailureError(message)
            self.ended(result: .failure)
            return
          }
          self.execute(.remove(record))
        }
    }
  }

  override func abort()
  {
    canceled = true
    if let alert = activeAlert, let parent = alert.window.sheetParent {
      parent.endSheet(alert.window, returnCode: .cancel)
    }
    // A Git command already running is allowed to finish; never kill it midway.
  }

  private func execute(_ command: WorktreeCommand)
  {
    guard let queue = windowController?.repoController.queue else {
      ended(result: .canceled)
      return
    }
    if case .remove(let record) = command,
       let blocker = removalRecheck?(record) {
      showFailureError(blocker)
      ended(result: .failure)
      return
    }
    let processCheck = removalProcessRecheck
    queue.executeOffMainThread { [weak self] in
      guard let self else { return }
      do {
        if self.canceled {
          Task { @MainActor in self.ended(result: .canceled) }
          return
        }
        let directory = try command.perform(removalPreflight: {
          if let blocker = processCheck?() {
            throw GitWorktreeCatalog.Failure.command(blocker)
          }
        })
        Task { @MainActor in
          self.createdDirectory = directory
          self.windowController?.repoController.refsChanged()
          self.ended(result: .success)
        }
      }
      catch {
        Task { @MainActor in
          // These errors already describe this worktree/CLI operation. Do not
          // append unrelated libgit2 thread-local errors from another checkout.
          self.showFailureError(error.localizedDescription)
          self.ended(result: .failure)
        }
      }
    }
  }

  override func ended(result: OperationResult = .success)
  {
    guard !completed else { return }
    completed = true
    form = nil
    activeAlert = nil
    let callback = finished
    finished = nil
    super.ended(result: result)
    callback?(result, createdDirectory)
  }
}

private enum WorktreeCommand: Sendable
{
  case create(WorktreeRecord, String, String)
  case remove(WorktreeRecord)

  func perform(removalPreflight: () throws -> Void) throws -> String?
  {
    switch self {
      case .create(let source, let branch, let destination):
        let inventory = try fresh(source)
        guard !branch.isEmpty, !branch.hasPrefix("-"),
              GitReference.isValidName("refs/heads/" + branch),
              destination.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: destination),
              let head = source.head else { throw failure("The branch or destination is no longer valid.") }
        let path = GitWorktreeCatalog.canonical(destination)
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory),
              isDirectory.boolValue, path != source.repositoryID,
              !path.hasPrefix(source.repositoryID + "/") else {
          throw failure("Choose a new directory outside Git metadata with an existing parent folder.")
        }
        let runner = try runner(inventory)
        _ = try runner.run(args: ["check-ref-format", "--branch", branch])
        _ = try runner.run(args: ["--git-dir", source.repositoryID,
                                  "cat-file", "-e", head + "^{commit}"])
        _ = try runner.run(args: ["--git-dir", source.repositoryID,
            "worktree", "add", "-b", branch, "--", path, head])
        return path
      case .remove(let record):
        let inventory = try fresh(record)
        guard !record.isPrimary,
              let current = inventory.records.first(where: { $0.id == record.id }),
              !current.isLocked else { throw failure("The primary or a locked worktree cannot be removed.") }
        let runner = try runner(inventory)
        let status = try runner.run(args: ["--git-dir", record.privateDirectory,
            "--work-tree", record.path, "status", "--porcelain=v1", "-z",
            "--untracked-files=all", "--ignored=matching"])
        guard status.isEmpty else {
          throw failure("This worktree contains changes, untracked or ignored files. Keep or move them before removing it. Nothing was deleted.")
        }
        // Revalidate the filesystem incarnation immediately before deletion.
        _ = try fresh(record)
        try removalPreflight()
        _ = try runner.run(args: ["--git-dir", record.repositoryID,
                                  "worktree", "remove", "--", record.path])
        return nil
    }
  }

  private func fresh(_ record: WorktreeRecord) throws -> WorktreeInventory
  {
    let inventory = try GitWorktreeCatalog.read(commonDirectory: record.repositoryID)
    guard let current = inventory.records.first(where: { $0.id == record.id }),
          current.path == record.path,
          current.privateDirectory == record.privateDirectory,
          current.availability == .available else {
      throw failure("The worktree moved, disappeared or was replaced. Refresh the Worktrees menu and try again. Nothing was changed.")
    }
    return inventory
  }

  private func runner(_ inventory: WorktreeInventory) throws -> CLIRunner
  {
    guard let primary = inventory.primary,
          primary.availability == .available else {
      throw failure("The primary checkout is unavailable. Nothing was changed.")
    }
    return CLIRunner(toolPath: "/usr/bin/git", workingDir: primary.path)
  }

  private func failure(_ message: String) -> Error
  { GitWorktreeCatalog.Failure.command(message) }
}
