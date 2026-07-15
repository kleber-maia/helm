import Cocoa

@MainActor
protocol HunkStaging: AnyObject
{
  func stage(hunk: any DiffHunk)
  func unstage(hunk: any DiffHunk)
  func discard(hunk: any DiffHunk)
}

enum EditorMode
{
  case diff
  case text
}

/// A fully-computed diff/text result, ready to render on the main thread.
/// Produced off the main thread (on the repository queue) so libgit2 work
/// never races with other repository operations.
///
/// `@unchecked Sendable` because it may carry `PatchMaker`/`Patch` (libgit2
/// reference types) across the queue → main boundary. These are only created
/// off-main and read on main, never used concurrently.
struct ComputedDiff: @unchecked Sendable
{
  let instruction: RenderInstruction
  let diffMaker: PatchMaker?
  let patch: (any Patch)?
}

/// Carries the non-Sendable inputs a diff computation needs across the
/// main → queue boundary. Safe because the queue accesses the repository
/// serially, never concurrently with the main thread.
struct DiffInput: @unchecked Sendable
{
  let fileList: any FileListModel
  let repo: (any FileContents & CommitReferencing)?
}

/// What the main thread should render. All payloads are value types so this
/// crosses isolation boundaries safely.
enum RenderInstruction: Sendable
{
  case clear
  /// Leave the current display untouched (e.g. patch generation failed).
  case keepCurrent
  case noChangesNotice
  case notice(UIString)
  case diff(json: String, ext: String, staging: String)
  case text(content: String, ext: String,
            added: [Int], deleted: [Int], modified: [Int])
}

/// Single controller managing a WKWebView that displays diffs or
/// full file text via CodeMirror.
final class FileDiffController: WebViewController,
                                WhitespaceVariable,
                                ContextVariable
{
  weak var stagingDelegate: (any HunkStaging)?
  weak var repo: (any FileContents & CommitReferencing)?
  var stagingType: StagingType = .none
  var patch: (any Patch)?
  var mode: EditorMode = .diff

  fileprivate var isLoaded_internal = false

  public var whitespace = UserDefaults.helm.whitespace
  {
    didSet { reloadCurrentSelection() }
  }
  public var contextLines = UInt(UserDefaults.helm.contextLines)
  {
    didSet { reloadCurrentSelection() }
  }
  var diffMaker: PatchMaker?

  /// The serial repository queue. Diff computation is dispatched here so it
  /// is serialized with all other libgit2 work on the shared repository,
  /// rather than running on the main thread (which forced the preview to
  /// wait — and visibly freeze — whenever the queue was busy).
  weak var queue: TaskQueue?

  /// Stored so we can re-render after mode switch.
  private var lastSelection: [FileSelection] = []
  /// Identifies the newest requested preview. Repository work is asynchronous;
  /// results from older generations must never replace a newer selection.
  private var renderGeneration: UInt64 = 0

  override func wrappingWidthAdjustment() -> Int
  {
    return 12
  }

  // MARK: - Diff computation (runs off the main thread)

  private nonisolated static func targetBlob(
      repo: (any FileContents & CommitReferencing)?,
      stagingType: StagingType,
      path: String) -> (any Blob)?
  {
    guard let headRef = repo?.headRefName
    else { return nil }

    switch stagingType {
      case .none:
        return nil
      case .index:
        return repo?.fileBlob(ref: headRef, path: path)
      case .workspace:
        return repo?.stagedBlob(file: path)
    }
  }

  private nonisolated static func targetLines(
      repo: (any FileContents & CommitReferencing)?,
      stagingType: StagingType,
      path: String) -> [String]?
  {
    guard let blob = targetBlob(repo: repo, stagingType: stagingType,
                                path: path)
    else { return nil }

    var lines: [String]?

    blob.withUnsafeBytes {
      (bytes) in
      var encoding = String.Encoding.utf8
      let text = String(data: bytes, usedEncoding: &encoding)

      lines = text?.components(separatedBy: .newlines)
    }
    return lines
  }

  private nonisolated static func decodeText(_ data: Data?) -> String
  {
    if let data = data,
       let decoded = String(data: data, encoding: .utf8) ??
                     String(data: data, encoding: .utf16)
    {
      return decoded
    }
    return ""
  }

  private nonisolated static func stagingTypeString(_ stagingType: StagingType) -> String
  {
    switch stagingType {
      case .none: return "none"
      case .index: return "index"
      case .workspace: return "workspace"
    }
  }

  /// Builds the render instruction for a single selection. Must run off the
  /// main thread (libgit2 access), serialized on the repository queue.
  nonisolated static func computeDiff(
      fileList: any FileListModel,
      path: String,
      repo: (any FileContents & CommitReferencing)?,
      stagingType: StagingType,
      mode: EditorMode,
      whitespace: WhitespaceSetting,
      contextLines: UInt) -> ComputedDiff
  {
    let diffResult = fileList.diffForFile(path)

    switch mode {
      case .diff:
        return computeDiffMode(
            diffResult: diffResult, repo: repo,
            stagingType: stagingType,
            whitespace: whitespace, contextLines: contextLines)
      case .text:
        let text = decodeText(fileList.dataForFile(path))
        let ext = (path as NSString).pathExtension
        let (added, deleted, modified) =
            changedLineNumbers(from: diffResult)

        return ComputedDiff(
            instruction: .text(content: text, ext: ext, added: added,
                               deleted: deleted, modified: modified),
            diffMaker: nil, patch: nil)
    }
  }

  private nonisolated static func computeDiffMode(
      diffResult: PatchMaker.PatchResult?,
      repo: (any FileContents & CommitReferencing)?,
      stagingType: StagingType,
      whitespace: WhitespaceSetting,
      contextLines: UInt) -> ComputedDiff
  {
    guard let diffResult = diffResult
    else {
      return ComputedDiff(instruction: .noChangesNotice,
                          diffMaker: nil, patch: nil)
    }

    switch diffResult {
      case .noDifference:
        return ComputedDiff(instruction: .noChangesNotice,
                            diffMaker: nil, patch: nil)
      case .binary:
        return ComputedDiff(instruction: .notice(.binaryFile),
                            diffMaker: nil, patch: nil)
      case .diff(let diffMaker):
        diffMaker.whitespace = whitespace
        diffMaker.contextLines = contextLines

        guard let patch = diffMaker.makePatch()
        else {
          return ComputedDiff(instruction: .keepCurrent,
                              diffMaker: diffMaker, patch: nil)
        }
        guard patch.hunkCount > 0
        else {
          return ComputedDiff(instruction: .noChangesNotice,
                              diffMaker: diffMaker, patch: patch)
        }

        let lines = targetLines(repo: repo, stagingType: stagingType,
                                path: diffMaker.path)
        let json = hunksJSON(patch: patch, targetLines: lines)
        let ext = (diffMaker.path as NSString).pathExtension

        return ComputedDiff(
            instruction: .diff(json: json, ext: ext,
                               staging: stagingTypeString(stagingType)),
            diffMaker: diffMaker, patch: patch)
    }
  }

  private nonisolated static func hunksJSON(patch: any Patch,
                                targetLines: [String]?) -> String
  {
    var hunks: [[String: Any]] = []

    for index in 0..<patch.hunkCount {
      guard let hunk = patch.hunk(at: index)
      else { continue }

      let canApply = targetLines.map {
        hunk.canApply(to: $0)
      } ?? true
      var lines: [[String: Any]] = []

      hunk.enumerateLines {
        (line) in
        let type: String
        switch line.type {
          case .addition: type = "addition"
          case .deletion: type = "deletion"
          default: type = "context"
        }
        lines.append([
          "type": type,
          "text": line.text,
          "oldLine": line.oldLine,
          "newLine": line.newLine,
        ])
      }

      hunks.append([
        "oldStart": hunk.oldStart,
        "oldLines": hunk.oldLines,
        "newStart": hunk.newStart,
        "newLines": hunk.newLines,
        "canApply": canApply,
        "lines": lines,
      ])
    }

    guard let data = try? JSONSerialization.data(
            withJSONObject: hunks, options: []),
          let json = String(data: data, encoding: .utf8)
    else { return "[]" }

    return json
  }

  /// Applies a computed result on the main thread: stores the patch (for
  /// hunk staging) and renders via the web view.
  @MainActor
  private func apply(_ result: ComputedDiff,
                     stagingType: StagingType,
                     generation: UInt64)
  {
    guard generation == renderGeneration
    else { return }

    self.stagingType = stagingType

    switch result.instruction {
      case .clear:
        renderClear(generation: generation)
      case .keepCurrent:
        // A failed patch must not leave a previous file's actionable hunks
        // visible for the new selection.
        renderClear(generation: generation)
      case .noChangesNotice:
        loadNoChangesNotice(generation: generation)
      case .notice(let text):
        loadNotice(text, generation: generation)
      case .diff(let json, let ext, let staging):
        ensureEditorLoaded()
        callJS("await HelmEditor.loadDiff(hunks, staging, ext)",
               arguments: ["hunks": json, "staging": staging, "ext": ext],
               when: generationCheck(generation)) {
          [weak self] succeeded in
          guard let self,
                succeeded,
                generation == self.renderGeneration
          else { return }

          self.diffMaker = result.diffMaker
          self.patch = result.patch
          self.stagingType = stagingType
          self.isLoaded = true
        }
      case .text(let content, let ext, let added, let deleted,
                 let modified):
        ensureEditorLoaded()
        let completion: (Bool) -> Void = {
          [weak self] succeeded in
          guard let self,
                succeeded,
                generation == self.renderGeneration
          else { return }

          self.isLoaded = true
        }
        if added.isEmpty && deleted.isEmpty && modified.isEmpty {
          callJS("await HelmEditor.loadText(content, ext)",
                 arguments: ["content": content, "ext": ext],
                 when: generationCheck(generation),
                 completion: completion)
        }
        else {
          callJS("""
              await HelmEditor.loadText(\
              content, ext, added, deleted, modified)
              """,
              arguments: [
                "content": content, "ext": ext,
                "added": added, "deleted": deleted,
                "modified": modified,
              ],
              when: generationCheck(generation),
              completion: completion)
        }
    }
  }

  private func generationCheck(_ generation: UInt64)
    -> () -> Bool
  {
    { [weak self] in self?.renderGeneration == generation }
  }

  private func renderClear(generation: UInt64)
  {
    diffMaker = nil
    patch = nil
    isLoaded = false
    ensureEditorLoaded()
    callJS("HelmEditor.clear()", when: generationCheck(generation))
  }

  func loadNoChangesNotice(generation: UInt64)
  {
    var notice: UIString

    switch stagingType {
      case .none:
        notice = .noChanges
      case .index:
        notice = .noStagedChanges
      case .workspace:
        notice = .noUnstagedChanges
    }
    loadNotice(notice, generation: generation)
  }

  // MARK: - Text mode

  /// Extracts changed line numbers from a diff result.
  /// Returns three sets of new-file line numbers:
  /// - `added`: pure additions (green gutter)
  /// - `modified`: replacement lines (blue gutter)
  /// - `deleted`: pure deletion points (red gutter)
  private nonisolated static func changedLineNumbers(
      from diffResult: PatchMaker.PatchResult?)
    -> (added: [Int], deleted: [Int],
        modified: [Int])
  {
    guard case .diff(let maker) = diffResult,
          let patch = maker.makePatch(),
          patch.hunkCount > 0
    else { return ([], [], []) }

    var addedSet = Set<Int>()
    var deletionPositions = Set<Int>()

    for i in 0..<patch.hunkCount {
      guard let hunk = patch.hunk(at: i)
      else { continue }

      var newPos = Int(hunk.newStart)
      var pendingDeletion = false

      hunk.enumerateLines { line in
        switch line.type {
          case .addition:
            addedSet.insert(Int(line.newLine))
            newPos = Int(line.newLine) + 1
            pendingDeletion = false
          case .deletion:
            if !pendingDeletion {
              deletionPositions.insert(max(newPos, 1))
              pendingDeletion = true
            }
          default:
            newPos = Int(line.newLine) + 1
            pendingDeletion = false
        }
      }
    }

    let overlap = addedSet.intersection(deletionPositions)
    let added = Array(addedSet.subtracting(overlap)).sorted()
    let deleted = Array(
        deletionPositions.subtracting(overlap)).sorted()
    let modified = Array(overlap).sorted()
    return (added, deleted, modified)
  }

  // MARK: - Notices

  func loadNotice(_ text: UIString, generation: UInt64)
  {
    diffMaker = nil
    patch = nil
    isLoaded = false
    ensureEditorLoaded()
    callJS("HelmEditor.loadNotice(message)",
           arguments: ["message": text.rawValue],
           when: generationCheck(generation)) {
      [weak self] succeeded in
      guard let self,
            succeeded,
            generation == self.renderGeneration
      else { return }

      self.isLoaded = true
    }
  }

  // MARK: - Hunk staging

  func hunk(at index: Int) -> (any DiffHunk)?
  {
    guard let patch = self.patch,
          (index >= 0) && (UInt(index) < patch.hunkCount)
    else { return nil }

    return patch.hunk(at: index)
  }

  func stageHunk(index: Int)
  {
    hunk(at: index).map { stagingDelegate?.stage(hunk: $0) }
  }

  func unstageHunk(index: Int)
  {
    hunk(at: index).map { stagingDelegate?.unstage(hunk: $0) }
  }

  func discardHunk(index: Int)
  {
    NSAlert.confirm(message: .confirmDiscardHunk,
                    actionName: .discard, isDestructive: true,
                    parentWindow: view.window!) {
      guard let hunk = self.hunk(at: index)
      else { return }

      self.stagingDelegate?.discard(hunk: hunk)
    }
  }

  override nonisolated func webMessage(action: String,
                                        sha: SHA?,
                                        index: Int?)
  {
    guard let index
    else { return }

    DispatchQueue.main.async {
      [self] in
      switch action {
        case "stageHunk":
          stageHunk(index: index)
        case "unstageHunk":
          unstageHunk(index: index)
        case "discardHunk":
          discardHunk(index: index)
        default:
          break
      }
    }
  }
}

// MARK: - FileContentLoading

extension FileDiffController: FileContentLoading
{
  var isLoaded: Bool
  {
    get
    { withSync { isLoaded_internal } }
    set
    { withSync { isLoaded_internal = newValue } }
  }

  public func clear()
  {
    renderGeneration &+= 1
    lastSelection = []
    stagingType = .none
    renderClear(generation: renderGeneration)
  }

  public func load(selection: [FileSelection])
  {
    renderGeneration &+= 1
    let generation = renderGeneration

    lastSelection = selection
    diffMaker = nil
    patch = nil
    isLoaded = false

    switch selection.count {
      case 0:
        lastSelection = []
        stagingType = .none
        renderClear(generation: generation)
      case 1:
        loadSingle(selection[0], generation: generation)
      default:
        loadNotice(.multipleItemsSelected, generation: generation)
    }
  }

  /// Computes the diff/text off the main thread on the repository queue,
  /// then renders the result on the main thread. Serializing the libgit2
  /// work with the queue means a busy queue no longer blocks the preview.
  private func loadSingle(_ selection: FileSelection,
                          generation: UInt64)
  {
    let input = DiffInput(fileList: selection.fileList, repo: repo)
    let path = selection.path
    let staging = selection.staging
    let mode = self.mode
    let whitespace = self.whitespace
    let contextLines = self.contextLines

    guard let queue = queue
    else {
      // No queue wired (e.g. unit tests): compute inline.
      let result = Self.computeDiff(
          fileList: input.fileList, path: path, repo: input.repo,
          stagingType: staging, mode: mode,
          whitespace: whitespace, contextLines: contextLines)

      apply(result, stagingType: staging, generation: generation)
      return
    }

    queue.executeAsync {
      [weak self] in
      guard let self = self
      else { return }

      let result = Self.computeDiff(
          fileList: input.fileList, path: path, repo: input.repo,
          stagingType: staging, mode: mode,
          whitespace: whitespace, contextLines: contextLines)

      await MainActor.run {
        self.apply(result, stagingType: staging,
                   generation: generation)
      }
    }
  }

  /// Re-renders the last loaded selection in the current mode.
  /// Called when the user toggles between diff and text.
  func reloadCurrentSelection()
  {
    isLoaded = false
    load(selection: lastSelection)
  }

  /// After the editor recovers from a web content process crash, the
  /// rendered diff/text was lost with the dead page. Re-render the current
  /// selection against the freshly reloaded editor.
  override func editorDidRecover()
  {
    reloadCurrentSelection()
  }
}
