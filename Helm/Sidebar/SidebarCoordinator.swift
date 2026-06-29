import SwiftUI

enum SidebarTreeSection: String, CaseIterable, Hashable, Identifiable
{
  case branches, remotes, tags, stashes, submodules

  var id: Self { self }

  var title: UIString
  {
    switch self {
      case .branches: .branches
      case .remotes: .remotes
      case .tags: .tags
      case .stashes: .stashes
      case .submodules: .submodules
    }
  }

  var systemImage: String
  {
    switch self {
      case .branches: "externaldrive"
      case .remotes: "network"
      case .tags: "tag"
      case .stashes: "tray"
      case .submodules: "square.split.bottomrightquarter"
    }
  }

  var path: String { "sidebar/\(rawValue)" }

  var axid: AXID
  {
    switch self {
      case .branches: .Sidebar.sectionBranches
      case .remotes: .Sidebar.sectionRemotes
      case .tags: .Sidebar.sectionTags
      case .stashes: .Sidebar.sectionStashes
      case .submodules: .Sidebar.sectionSubmodules
    }
  }
}

enum SidebarTreeSelection: Hashable
{
  case section(SidebarTreeSection)
  case staging
  case localBranch(LocalBranchRefName)
  case remote(name: String)
  case remoteBranch(ref: RemoteBranchRefName)
  case tag(TagRefName)
  case stash(GitOID)
  case submodule(String)
}

// Legacy selection types kept so the older per-section sidebar views continue
// to compile while the unified tree replaces them at runtime.
enum BranchListSelection: Hashable
{
  case staging
  case branch(LocalBranchRefName)
}

enum RemoteListSelection: Hashable
{
  case remote(name: String)
  case branch(ref: RemoteBranchRefName)
}

/// Delegate that executes sidebar commands on behalf of the SwiftUI sidebar.
@MainActor
protocol SidebarCoordinatorDelegate: AnyObject
{
  func newBranch()
  func newRemote()
  func checkoutBranch(_ branch: LocalBranchRefName)
  func mergeBranch(_ branch: LocalBranchRefName)
  func renameBranch(_ branch: LocalBranchRefName)
  func deleteBranch(_ branch: LocalBranchRefName)
  func deleteBranchAndRemote(_ branch: LocalBranchRefName)
  func createTrackingBranch(_ branch: RemoteBranchRefName)
  func mergeRemoteBranch(_ branch: RemoteBranchRefName)
  func renameRemote(_ remote: String)
  func editRemote(_ remote: String)
  func deleteRemote(_ remote: String)
  func copyRemoteURL(_ remote: String)
  func copyBranchName(_ name: String)
  func deleteTag(_ tag: TagRefName)
  func popStash(_ stashID: GitOID)
  func applyStash(_ stashID: GitOID)
  func dropStash(_ stashID: GitOID)
  func showSubmoduleInFinder(_ name: String)
  func updateSubmodule(_ name: String)
  func refreshSidebar()
  func reselect(_ selection: SidebarTreeSelection)
}

/// Presentation data for the tag info popover.
struct TagInfoModel: Identifiable
{
  let tagName: String
  let authorName: String
  let authorEmail: String
  let date: Date
  let message: String

  var id: String { tagName }
}

/// Central coordinator for SwiftUI sidebar state and command dispatch.
@MainActor
final class SidebarCoordinator: ObservableObject
{
  /// Current selection in the unified sidebar tree.
  @Published var selection: SidebarTreeSelection?

  /// Graph line color of the HEAD commit, updated by the history view.
  @Published var headGraphColor: Color = Color(nsColor:
      HistoryCellView.lineColors[0])

  /// Expanded nodes in the unified sidebar tree.
  @Published var expandedItems: Set<String> = []

  /// Current annotated tag popover payload, if one is being shown.
  @Published var presentedTagInfo: TagInfoModel?

  /// Delegate supplied by `TabbedSidebarController`.
  weak var delegate: (any SidebarCoordinatorDelegate)?

  /// Convenience wrappers used by SwiftUI views instead of calling closures
  /// directly. Keeping these methods centralized makes later validation or
  /// enablement changes easier.
  func newBranch() { delegate?.newBranch() }
  func newRemote() { delegate?.newRemote() }
  func checkoutBranch(_ branch: LocalBranchRefName) { delegate?.checkoutBranch(branch) }
  func mergeBranch(_ branch: LocalBranchRefName) { delegate?.mergeBranch(branch) }
  func renameBranch(_ branch: LocalBranchRefName) { delegate?.renameBranch(branch) }
  func deleteBranch(_ branch: LocalBranchRefName) { delegate?.deleteBranch(branch) }
  func deleteBranchAndRemote(_ branch: LocalBranchRefName)
  { delegate?.deleteBranchAndRemote(branch) }
  func createTrackingBranch(_ branch: RemoteBranchRefName)
  { delegate?.createTrackingBranch(branch) }
  func mergeRemoteBranch(_ branch: RemoteBranchRefName)
  { delegate?.mergeRemoteBranch(branch) }
  func renameRemote(_ remote: String) { delegate?.renameRemote(remote) }
  func editRemote(_ remote: String) { delegate?.editRemote(remote) }
  func deleteRemote(_ remote: String) { delegate?.deleteRemote(remote) }
  func copyRemoteURL(_ remote: String) { delegate?.copyRemoteURL(remote) }
  func copyBranchName(_ name: String) { delegate?.copyBranchName(name) }
  func deleteTag(_ tag: TagRefName) { delegate?.deleteTag(tag) }

  /// Presents the annotated-tag popover.
  func showTagInfo(_ presentation: TagInfoModel)
  {
    presentedTagInfo = presentation
  }

  func dismissTagInfo()
  {
    presentedTagInfo = nil
  }

  func popStash(_ stashID: GitOID) { delegate?.popStash(stashID) }
  func applyStash(_ stashID: GitOID) { delegate?.applyStash(stashID) }
  func dropStash(_ stashID: GitOID) { delegate?.dropStash(stashID) }
  func showSubmoduleInFinder(_ name: String) { delegate?.showSubmoduleInFinder(name) }
  func updateSubmodule(_ name: String) { delegate?.updateSubmodule(name) }

  /// Re-runs the sidebar models' refresh logic.
  func refresh() { delegate?.refreshSidebar() }

  /// Re-applies the given selection to the history view, even when the
  /// sidebar's selected row is unchanged (e.g. the user re-clicked it).
  func reselect(_ selection: SidebarTreeSelection)
  {
    delegate?.reselect(selection)
  }
}
