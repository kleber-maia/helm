import Combine
import Foundation

/// Common refresh surface for the cached sidebar models owned by the host controller.
@MainActor
protocol SidebarViewModelRefreshing: AnyObject
{
  func refresh()
}

struct SidebarTagItem: Identifiable, Hashable, PathTreeData
{
  let name: TagRefName
  let type: TagType
  let isSigned: Bool
  let info: TagInfoModel?

  var id: String { name.rawValue }
  var treeNodePath: String { "sidebar/tags/\(name.rawValue)" }

  static func == (lhs: Self, rhs: Self) -> Bool
  {
    lhs.name == rhs.name &&
      lhs.type == rhs.type &&
      lhs.isSigned == rhs.isSigned
  }

  func hash(into hasher: inout Hasher)
  {
    hasher.combine(name)
    hasher.combine(type)
    hasher.combine(isSigned)
  }
}

struct SidebarRemoteBranchItem: Hashable, PathTreeData
{
  let refName: RemoteBranchRefName

  var treeNodePath: String
  { "sidebar/remotes/\(refName.remoteName)/\(refName.name)" }
}

struct SidebarStashItem: Identifiable, Hashable, PathTreeData
{
  let id: GitOID
  let message: String
  let date: Date?
  let unstagedCount: Int
  let stagedCount: Int

  var treeNodePath: String { "sidebar/stashes/\(id.sha)" }
}

struct SidebarSubmoduleItem: Identifiable, Hashable, PathTreeData
{
  let name: String

  var id: String { name }
  var treeNodePath: String { "sidebar/submodules/\(name)" }
}

enum SidebarTreeItem: Hashable, PathTreeData
{
  case section(SidebarTreeSection)
  case staging
  case localBranch(BranchListItem)
  case remote(String)
  case remoteBranch(SidebarRemoteBranchItem)
  case tag(SidebarTagItem)
  case stash(SidebarStashItem)
  case submodule(SidebarSubmoduleItem)

  var treeNodePath: String
  {
    switch self {
      case .section(let section):
        section.path
      case .staging:
        "sidebar/staging"
      case .localBranch(let item):
        "sidebar/branches/\(item.refName.name)"
      case .remote(let name):
        "sidebar/remotes/\(name)"
      case .remoteBranch(let item):
        item.treeNodePath
      case .tag(let item):
        item.treeNodePath
      case .stash(let item):
        item.treeNodePath
      case .submodule(let item):
        item.treeNodePath
    }
  }

  var selection: SidebarTreeSelection
  {
    switch self {
      case .section(let section):
        .section(section)
      case .staging:
        .staging
      case .localBranch(let item):
        .localBranch(item.refName)
      case .remote(let name):
        .remote(name: name)
      case .remoteBranch(let item):
        .remoteBranch(ref: item.refName)
      case .tag(let item):
        .tag(item.name)
      case .stash(let item):
        .stash(item.id)
      case .submodule(let item):
        .submodule(item.name)
    }
  }

  func matches(filter text: LowerCaseString) -> Bool
  {
    switch self {
      case .section(let section):
        return section.title.rawValue.lowercased().contains(text.rawValue)
      case .staging:
        return UIString.staging.rawValue.lowercased().contains(text.rawValue)
      case .localBranch(let item):
        return item.refName.name.lowercased().contains(text.rawValue)
      case .remote(let name):
        return name.lowercased().contains(text.rawValue)
      case .remoteBranch(let item):
        let textToMatch = "\(item.refName.remoteName)/\(item.refName.name)"
        return textToMatch.lowercased().contains(text.rawValue)
      case .tag(let item):
        return item.name.rawValue.lowercased().contains(text.rawValue)
      case .stash(let item):
        return item.message.lowercased().contains(text.rawValue)
      case .submodule(let item):
        return item.name.lowercased().contains(text.rawValue)
    }
  }
}

/// Cached view model for the entire sidebar.
///
/// This owns the unified sidebar tree and refreshes it independently of the
/// SwiftUI view lifecycle.
@MainActor
final class SidebarViewModel<Brancher, Manager, Referencer, Stasher, Tagger, SubManager>
  : FilteringListViewModel, SidebarViewModelRefreshing
  where Brancher: Branching, Manager: RemoteManagement,
        Referencer: CommitReferencing,
        Stasher: Stashing, Tagger: Tagging,
        SubManager: SubmoduleManagement,
        Brancher.LocalBranch == Referencer.LocalBranch
{
  let brancher: Brancher
  let manager: Manager
  let referencer: Referencer
  let stasher: Stasher
  let tagger: Tagger
  let submoduleManager: SubManager

  @Published var workspaceCountModel: WorkspaceStatusCountModel
  @Published private(set) var items: [PathTreeNode<SidebarTreeItem>] = []
  @Published private(set) var autoExpandedItems: Set<String> = []

  private var unfilteredItems: [PathTreeNode<SidebarTreeItem>] = []

  init(brancher: Brancher,
       detector _: any FileStatusDetection,
       remoteManager: Manager,
       referencer: Referencer,
       publisher: any RepositoryPublishing,
       stasher: Stasher,
       submoduleManager: SubManager,
       tagger: Tagger,
       workspaceCountModel: WorkspaceStatusCountModel)
  {
    self.brancher = brancher
    self.manager = remoteManager
    self.referencer = referencer
    self.stasher = stasher
    self.tagger = tagger
    self.submoduleManager = submoduleManager
    self.workspaceCountModel = workspaceCountModel
    super.init()

    refresh()
    sinks.append(contentsOf: [
      publisher.refsPublisher.sinkOnMainQueue { [weak self] in
        self?.refresh()
      },
      publisher.configPublisher.sinkOnMainQueue { [weak self] in
        self?.refresh()
      },
      publisher.stashPublisher.sinkOnMainQueue { [weak self] in
        self?.refresh()
      },
      workspaceCountModel.objectWillChange.sinkOnMainQueue { [weak self] _ in
        self?.objectWillChange.send()
      },
    ])
  }

  func refresh()
  {
    unfilteredItems = buildTree()
    applyFilter(filter)
  }

  override func filterChanged(_ newFilter: String)
  {
    applyFilter(newFilter)
  }

  func expandedItems(saved: Set<String>) -> Set<String>
  {
    let base = filter.isEmpty ? saved : saved.union(autoExpandedItems)

    return base.union(branchFolderPaths)
  }

  /// All folder paths under the Branches section, so branches
  /// always appear fully expanded.
  private var branchFolderPaths: Set<String>
  {
    guard let branchesNode = items.first(
              where: { $0.item == .section(.branches) }),
          let children = branchesNode.children
    else { return [] }

    return expandedPaths(in: children)
  }

  private func applyFilter(_ newFilter: String)
  {
    guard !newFilter.isEmpty
    else {
      items = unfilteredItems
      autoExpandedItems = []
      return
    }

    let lowerCased = LowerCaseString(newFilter)
    let filteredItems = unfilteredItems.compactMap {
      filtered(node: $0, text: lowerCased)
    }

    items = filteredItems
    autoExpandedItems = expandedPaths(in: filteredItems)
  }

  private func buildTree() -> [PathTreeNode<SidebarTreeItem>]
  {
    [
      .leaf(.staging),
      .node(item: .section(.branches), children: branchChildren()),
      .node(item: .section(.remotes), children: remoteChildren()),
      .node(item: .section(.tags), children: tagChildren()),
      .node(item: .section(.stashes), children: stashChildren()),
      .node(item: .section(.submodules), children: submoduleChildren()),
    ]
  }

  private func branchChildren() -> [PathTreeNode<SidebarTreeItem>]
  {
    let currentBranch = brancher.currentBranch
    let branches = brancher.localBranches
      .sorted(byKeyPath: \.referenceName.fullPath)
      .map {
        SidebarTreeItem.localBranch(
            .init(refName: $0.referenceName,
                  trackingRefName: $0.trackingBranch?.referenceName,
                  isCurrent: $0.referenceName == currentBranch,
                  graphStatus: branchStatus($0)))
      }
    let hierarchy = PathTreeNode.makeHierarchy(from: branches,
                                               prefix: "sidebar/branches/")

    return hierarchy
  }

  private func remoteChildren() -> [PathTreeNode<SidebarTreeItem>]
  {
    var branchesByRemote: [String: [SidebarRemoteBranchItem]] = [:]

    for branch in brancher.remoteBranches {
      if let remoteName = branch.remoteName {
        branchesByRemote[remoteName, default: []]
          .append(.init(refName: branch.referenceName))
      }
    }

    let remoteNames = Set(manager.remoteNames()).union(branchesByRemote.keys)

    return remoteNames.sorted().map { remoteName in
      let branchItems = branchesByRemote[remoteName, default: []]
        .sorted(byKeyPath: \.refName.name)
      let children = PathTreeNode.makeHierarchy(from: branchItems,
                                                prefix: "sidebar/remotes/\(remoteName)/")
        .map(mapRemoteNode)

      if children.isEmpty {
        return .leaf(.remote(remoteName))
      }
      else {
        return .node(item: .remote(remoteName), children: children)
      }
    }
  }

  private func tagChildren() -> [PathTreeNode<SidebarTreeItem>]
  {
    let tags = (try? tagger.tags()) ?? []
    let items = tags.map {
      SidebarTreeItem.tag(
          .init(name: $0.name,
                type: $0.type,
                isSigned: $0.isSigned,
                info: tagInfo(for: $0)))
    }

    return PathTreeNode.makeHierarchy(from: items, prefix: "sidebar/tags/")
  }

  private func stashChildren() -> [PathTreeNode<SidebarTreeItem>]
  {
    stasher.stashes.map {
      .leaf(.stash(.init(id: $0.id,
                         message: $0.mainCommit?.messageSummary ?? "WIP",
                         date: $0.mainCommit?.commitDate,
                         unstagedCount: $0.workspaceChanges().count,
                         stagedCount: $0.indexChanges().count)))
    }
  }

  private func submoduleChildren() -> [PathTreeNode<SidebarTreeItem>]
  {
    submoduleManager.submodules().map {
      .leaf(.submodule(.init(name: $0.name)))
    }
  }

  private func branchStatus(_ branch: Brancher.LocalBranch) -> GraphStatus
  {
    guard let trackingBranch = branch.trackingBranch,
          let status = referencer.graphBetween(
                localBranch: branch.referenceName,
                upstreamBranch: trackingBranch.referenceName)
    else { return .zero }

    return status
  }

  private func tagInfo(for tag: Tagger.Tag) -> TagInfoModel?
  {
    guard tag.type == .annotated
    else { return nil }

    return .init(tagName: tag.name.rawValue,
                 authorName: tag.signature?.name ?? "-",
                 authorEmail: tag.signature?.email ?? "",
                 date: tag.signature?.when ?? .distantPast,
                 message: tag.message ?? "")
  }

  private func mapRemoteNode(_ node: PathTreeNode<SidebarRemoteBranchItem>)
      -> PathTreeNode<SidebarTreeItem>
  {
    switch node {
      case .leaf(let item):
        return .leaf(.remoteBranch(item))
      case .node(let content, let children):
        switch content {
          case .item(let item):
            return .node(item: .remoteBranch(item),
                         children: children.map(mapRemoteNode))
          case .virtual(let path):
            return .node(path: path,
                         children: children.map(mapRemoteNode))
        }
    }
  }

  private func filtered(node: PathTreeNode<SidebarTreeItem>,
                        text: LowerCaseString) -> PathTreeNode<SidebarTreeItem>?
  {
    let selfMatches = node.item.map { $0.matches(filter: text) } ??
      node.path.lowercased().contains(text.rawValue)

    switch node {
      case .leaf:
        return selfMatches ? node : nil

      case .node(let content, let children):
        if selfMatches {
          return .node(content: content, children: children)
        }

        let filteredChildren = children.compactMap { filtered(node: $0, text: text) }
        guard !filteredChildren.isEmpty
        else { return nil }

        return .node(content: content, children: filteredChildren)
    }
  }

  private func expandedPaths(in items: [PathTreeNode<SidebarTreeItem>]) -> Set<String>
  {
    items.reduce(into: Set<String>()) { result, item in
      guard let children = item.children
      else { return }

      result.insert(item.path)
      result.formUnion(expandedPaths(in: children))
    }
  }
}
