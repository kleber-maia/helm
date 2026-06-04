import Foundation

/// Changes for a selected commit in the history
public final class CommitSelection: RepositorySelection
{
  public unowned var repository: any FileChangesRepo
  public let commit: any Commit
  public var target: SelectionTarget { .oid(commit.id) }
  public var canCommit: Bool { false }
  public var fileList: any FileListModel { commitFileList }
  
  // Initialization requires a reference to self
  private(set) var commitFileList: CommitFileList!
  
  /// SHA of the parent commit to use for diffs
  var diffParent: GitOID?

  public init(repository: any FileChangesRepo, commit: any Commit)
  {
    self.repository = repository
    self.commit = commit
    
    commitFileList = CommitFileList(repository: repository,
                                    commit: commit,
                                    diffParent: diffParent)
  }
}

final class CommitFileList: FileListModel
{
  unowned var repository: any FileChangesRepo
  lazy var changes: [FileChange] =
      self.repository.changes(for: self.commit.id,
                              parent: self.commit.parentOIDs.first)
  
  let commit: any Commit
  let diffParent: GitOID?

  init(repository: any FileChangesRepo,
       commit: any Commit,
       diffParent: GitOID? = nil)
  {
    self.repository = repository
    self.commit = commit
    self.diffParent = diffParent
  }

  func equals(_ other: any FileListModel) -> Bool
  {
    guard let other = other as? CommitFileList
    else { return false }
    return commit.id == other.commit.id && diffParent == other.diffParent
  }
  
  func treeRoot(oldTree: FileChangeNode?) -> FileChangeNode
  {
    treeRoot(oldTree: oldTree, commit: commit)
  }

  /// Generic to unbox `commit`
  func treeRoot(oldTree: FileChangeNode?, commit: some Commit) -> FileChangeNode
  {
    let changeList = repository.changes(for: commit.id, parent: diffParent)
    let root = FileChangeNode(
        value: FileChange(path: FileChangeNode.rootName + "/"))

    for change in changeList {
      root.add(fileChange: change)
    }
    postProcess(fileTree: root)
    return root
  }

  func diffForFile(_ path: String) -> PatchMaker.PatchResult?
  {
    return repository.diffMaker(forFile: path,
                                commitOID: commit.id,
                                parentOID: diffParent ??
                                           commit.parentOIDs.first)
  }
  
  func blame(for path: String) -> (any Blame)?
  {
    return repository.blame(for: path, from: commit.id, to: nil)
  }
  
  func dataForFile(_ path: String) -> Data?
  {
    return repository.contentsOfFile(path: path, at: commit)
  }
  
  func fileURL(_ path: String) -> URL?
  {
    return nil
  }
}
