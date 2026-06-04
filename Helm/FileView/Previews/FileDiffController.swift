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
    didSet { configureDiffMaker() }
  }
  public var contextLines = UInt(UserDefaults.helm.contextLines)
  {
    didSet { configureDiffMaker() }
  }
  var diffMaker: PatchMaker?
  {
    didSet { configureDiffMaker() }
  }

  /// Stored so we can re-render after mode switch.
  private var lastSelection: [FileSelection] = []

  override func wrappingWidthAdjustment() -> Int
  {
    return 12
  }

  private func configureDiffMaker()
  {
    diffMaker?.whitespace = whitespace
    diffMaker?.contextLines = contextLines
    reloadDiff()
  }

  // MARK: - Diff mode

  func diffTargetBlob() -> (any Blob)?
  {
    guard let diffMaker = diffMaker,
          let headRef = repo?.headRefName
    else { return nil }

    switch stagingType {
      case .none:
        return nil
      case .index:
        return repo?.fileBlob(ref: headRef, path: diffMaker.path)
      case .workspace:
        return repo?.stagedBlob(file: diffMaker.path)
    }
  }

  private func fileExtensionForDiff() -> String
  {
    guard let path = diffMaker?.path
    else { return "" }
    return (path as NSString).pathExtension
  }

  private func stagingTypeString() -> String
  {
    switch stagingType {
      case .none: return "none"
      case .index: return "index"
      case .workspace: return "workspace"
    }
  }

  private func hunksJSON(patch: any Patch,
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

  func reloadDiff()
  {
    guard let diffMaker = diffMaker,
          let patch = diffMaker.makePatch()
    else {
      self.patch = nil
      return
    }

    self.patch = patch

    guard patch.hunkCount > 0
    else {
      loadNoChangesNotice()
      return
    }

    var targetLines: [String]?

    if let blob = diffTargetBlob() {
      blob.withUnsafeBytes {
        (bytes) in
        var encoding = String.Encoding.utf8
        let text = String(data: bytes, usedEncoding: &encoding)

        targetLines = text?.components(separatedBy: .newlines)
      }
    }

    let json = hunksJSON(patch: patch, targetLines: targetLines)
    let ext = fileExtensionForDiff()
    let staging = stagingTypeString()

    ensureEditorLoaded()
    callJS("await HelmEditor.loadDiff(hunks, staging, ext)",
           arguments: ["hunks": json, "staging": staging, "ext": ext])
    isLoaded = true
  }

  func loadOrNotify(diffResult: PatchMaker.PatchResult?)
  {
    if let diffResult = diffResult {
      switch diffResult {
        case .noDifference:
          loadNoChangesNotice()
        case .binary:
          loadNotice(.binaryFile)
        case .diff(let diffMaker):
          self.diffMaker = diffMaker
      }
    }
    else {
      loadNoChangesNotice()
    }
  }

  func loadNoChangesNotice()
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
    loadNotice(notice)
  }

  // MARK: - Text mode

  func loadText(data: Data?, path: String,
                diffResult: PatchMaker.PatchResult? = nil)
  {
    let text: String

    if let data = data,
       let decoded = String(data: data, encoding: .utf8) ??
                     String(data: data, encoding: .utf16)
    {
      text = decoded
    }
    else {
      text = ""
    }

    loadText(text: text, path: path,
             diffResult: diffResult)
  }

  func loadText(text: String, path: String,
                diffResult: PatchMaker.PatchResult? = nil)
  {
    let ext = (path as NSString).pathExtension
    let (added, deleted, modified) =
        changedLineNumbers(from: diffResult)

    ensureEditorLoaded()
    if added.isEmpty && deleted.isEmpty && modified.isEmpty {
      callJS("await HelmEditor.loadText(content, ext)",
             arguments: ["content": text, "ext": ext])
    }
    else {
      callJS("""
          await HelmEditor.loadText(\
          content, ext, added, deleted, modified)
          """,
          arguments: [
            "content": text, "ext": ext,
            "added": added, "deleted": deleted,
            "modified": modified,
          ])
    }
    isLoaded = true
  }

  /// Extracts changed line numbers from a diff result.
  /// Returns three sets of new-file line numbers:
  /// - `added`: pure additions (green gutter)
  /// - `modified`: replacement lines (blue gutter)
  /// - `deleted`: pure deletion points (red gutter)
  private func changedLineNumbers(
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

  func loadNotice(_ text: UIString)
  {
    let escaped = text.rawValue
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")

    ensureEditorLoaded()
    evaluateJS("HelmEditor.loadNotice('\(escaped)')")
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
    isLoaded = false
    lastSelection = []
    guard editorReady else { return }
    evaluateJS("HelmEditor.clear()")
  }

  public func load(selection: [FileSelection])
  {
    lastSelection = selection

    switch selection.count {
      case 0:
        clear()
        return
      case 1:
        self.stagingType = selection[0].staging

        let fileList = selection[0].fileList
        let path = selection[0].path
        let diffResult = fileList.diffForFile(path)

        switch mode {
          case .diff:
            loadOrNotify(diffResult: diffResult)
          case .text:
            loadText(
              data: fileList.dataForFile(path),
              path: path,
              diffResult: diffResult)
        }
      default:
        loadNotice(.multipleItemsSelected)
    }
  }

  /// Re-renders the last loaded selection in the current mode.
  /// Called when the user toggles between diff and text.
  func reloadCurrentSelection()
  {
    isLoaded = false
    load(selection: lastSelection)
  }
}
