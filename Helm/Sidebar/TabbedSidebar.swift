import SwiftUI

let sidebarDateFormatStyle = Date.FormatStyle()
  .day(.twoDigits)
  .month(.twoDigits)
  .year(.twoDigits)

extension FormatStyle where Self == Date.FormatStyle
{
  static var sidebar: Self { sidebarDateFormatStyle }
}

struct TabbedSidebar<Brancher, Manager, Referencer, Stasher, Tagger, SubManager>: View
  where Brancher: Branching, Manager: RemoteManagement,
        Referencer: CommitReferencing,
        Stasher: Stashing, Tagger: Tagging, SubManager: SubmoduleManagement,
        Brancher.LocalBranch == Referencer.LocalBranch,
        Brancher.RemoteBranch == Referencer.RemoteBranch
{
  @ObservedObject var model: SidebarViewModel<Brancher, Manager, Referencer,
                                              Stasher, Tagger, SubManager>

  @State private var listSelection: SidebarTreeSelection?
  @State private var listExpandedItems: Set<String>

  @EnvironmentObject private var coordinator: SidebarCoordinator
  @EnvironmentObject private var accessories: BranchAccessoryStore

  var body: some View
  {
    VStack(spacing: 0) {
      List(selection: $listSelection) {
        RecursiveDisclosureGroup(model.items,
                                 expandedItems: effectiveExpandedItems,
                                 tagForElement: { selectionTag(for: $0) }) {
          node in
          row(for: node)
        }
      }
        .axid(.Sidebar.tree)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: SidebarTreeSelection.self) { _ in
        } primaryAction: { selections in
          guard let selection = selections.first
          else { return }
          switch selection {
            case .localBranch(let refName):
              coordinator.checkoutBranch(refName)
            case .remoteBranch(let ref):
              coordinator.createTrackingBranch(ref)
            default:
              break
          }
        }
        .overlay {
          if model.items.isEmpty {
            model.contentUnavailableView("Sidebar", systemImage: "sidebar.left")
          }
        }
      FilterBar(text: $model.filter)
        .onChange(of: listSelection) {
          let newSelection = listSelection
          guard coordinator.selection != newSelection
          else { return }
          DispatchQueue.main.async {
            coordinator.selection = newSelection
          }
        }
        .onChange(of: coordinator.selection) {
          guard listSelection != coordinator.selection
          else { return }
          listSelection = coordinator.selection
        }
        .onChange(of: listExpandedItems) {
          let newExpanded = listExpandedItems
          guard coordinator.expandedItems != newExpanded
          else { return }
          DispatchQueue.main.async {
            coordinator.expandedItems = newExpanded
          }
        }
        .onChange(of: coordinator.expandedItems, initial: true) {
          guard listExpandedItems != coordinator.expandedItems
          else { return }
          listExpandedItems = coordinator.expandedItems
        }
    }
      .listStyle(.sidebar)
      .background(.clear)
      .frame(minWidth: 200, maxWidth: .infinity)
      .accessibilityElement(children: .contain)
      .axid(.Sidebar.list)
  }

  init(model: SidebarViewModel<Brancher, Manager, Referencer, Stasher,
                               Tagger, SubManager>)
  {
    self.model = model
    self._listSelection = State(initialValue: nil)
    self._listExpandedItems = State(initialValue: [])
  }

  private var effectiveExpandedItems: Binding<Set<String>>
  {
    Binding {
      model.expandedItems(saved: listExpandedItems)
    } set: {
      listExpandedItems = $0.subtracting(model.autoExpandedItems)
    }
  }

  @ViewBuilder
  private func row(for node: PathTreeNode<SidebarTreeItem>) -> some View
  {
    switch node.item {
      case .section(let section):
        sectionRow(for: section)
      case .staging:
        stagingRow()
      case .localBranch(let branch):
        branchRow(for: node, branch: branch)
      case .remote(let remoteName):
        remoteRow(for: remoteName, node: node)
      case .remoteBranch(let branch):
        remoteBranchRow(for: node, branch: branch)
      case .tag(let tag):
        tagRow(for: tag)
      case .stash(let stash):
        stashRow(for: stash)
      case .submodule(let submodule):
        submoduleRow(for: submodule)
      case nil:
        folderRow(for: node.path.lastPathComponent)
          .onTapGesture(count: 2) {
            if coordinator.expandedItems.contains(node.path) {
              coordinator.expandedItems.remove(node.path)
            }
            else {
              coordinator.expandedItems.insert(node.path)
            }
          }
    }
  }

  private func selectionTag(
      for node: PathTreeNode<SidebarTreeItem>)
    -> SidebarTreeSelection?
  {
    switch node.item {
      case .section(let section): .section(section)
      case .staging: .staging
      case .localBranch(let b): .localBranch(b.refName)
      case .remote(let name): .remote(name: name)
      case .remoteBranch(let b): .remoteBranch(ref: b.refName)
      case .tag(let t): .tag(t.name)
      case .stash(let s): .stash(s.id)
      case .submodule(let s): .submodule(s.name)
      case nil: nil
    }
  }

  @ViewBuilder
  private func sectionRow(for section: SidebarTreeSection) -> some View
  {
    HStack(spacing: 4) {
      Image(systemName: section.systemImage)
        .frame(width: 16, alignment: .center)
      Text(section.title.rawValue)
        .axid(section.axid)
      Spacer()
      SidebarActionButton {
        sectionActionMenu(for: section)
      }
    }
      .fontWeight(.semibold)
      .foregroundStyle(.secondary)
      .contentShape(Rectangle())
      .listRowSeparator(.hidden)
  }

  @ViewBuilder
  private func stagingRow() -> some View
  {
    StagingRow(countModel: model.workspaceCountModel,
               isSelected: listSelection == .staging)
  }

  @ViewBuilder
  private func branchRow(for node: PathTreeNode<SidebarTreeItem>,
                         branch: BranchListItem) -> some View
  {
    BranchCell(node: node, isCurrent: branch.isCurrent, trailingContent: {
      upstreamIndicator(for: branch)
      let _ = accessories.revision
      accessories.accessory(for: branch.refName)
    }, contextMenu: {
      branchContextMenu(for: branch.refName)
    })
  }

  @ViewBuilder
  private func remoteRow(for remoteName: String,
                         node _: PathTreeNode<SidebarTreeItem>) -> some View
  {
    HStack(spacing: 4) {
      Image(systemName: "network")
        .frame(width: 16, alignment: .center)
      Text(remoteName)
      Spacer()
    }
      .contentShape(Rectangle())
      .listRowSeparator(.hidden)
      .contextMenu {
        remoteContextMenu(for: remoteName)
      }
  }

  @ViewBuilder
  private func remoteBranchRow(for node: PathTreeNode<SidebarTreeItem>,
                               branch: SidebarRemoteBranchItem) -> some View
  {
    BranchCell(node: node, trailingContent: {
      let _ = accessories.revision
      accessories.accessory(for: branch.refName)
    }, contextMenu: {
      remoteBranchContextMenu(for: branch.refName)
    })
  }

  @ViewBuilder
  private func tagRow(for tag: SidebarTagItem) -> some View
  {
    HStack {
      Text(tag.name.rawValue.lastPathComponent)
      Spacer()
      if let info = tag.info {
        Button {
          coordinator.showTagInfo(info)
        } label: {
          Image(systemName: "info.circle")
        }
          .buttonStyle(.borderless)
          .popover(isPresented: tagInfoBinding(for: info), arrowEdge: .bottom) {
            TagInfoView(presentation: info)
          }
      }
    }
      .contentShape(Rectangle())
      .listRowSeparator(.hidden)
      .contextMenu {
        tagContextMenu(for: tag.name)
      }
  }

  @ViewBuilder
  private func stashRow(for stash: SidebarStashItem) -> some View
  {
    HStack {
      ExpansionText(stash.message)
      Spacer()
    }
      .contentShape(Rectangle())
      .listRowSeparator(.hidden)
      .contextMenu {
        stashContextMenu(for: stash.id)
      }
  }

  @ViewBuilder
  private func submoduleRow(for submodule: SidebarSubmoduleItem) -> some View
  {
    Text(submodule.name)
      .contentShape(Rectangle())
      .listRowSeparator(.hidden)
      .contextMenu {
        submoduleContextMenu(for: submodule.name)
      }
  }

  @ViewBuilder
  private func folderRow(for name: String) -> some View
  {
    HStack(spacing: 4) {
      Image(systemName: "folder.fill")
        .frame(width: 16, alignment: .center)
      Text(name)
      Spacer()
    }
      .contentShape(Rectangle())
      .listRowSeparator(.hidden)
      .selectionDisabled(true)
  }

  @ViewBuilder
  private func sectionActionMenu(for section: SidebarTreeSection) -> some View
  {
    switch section {
      case .branches:
        branchesActionMenu()
      case .remotes:
        remotesActionMenu()
      case .tags:
        tagsActionMenu()
      case .stashes:
        stashesActionMenu()
      case .submodules:
        submodulesActionMenu()
    }
  }

  @ViewBuilder
  private func branchesActionMenu() -> some View
  {
    let branchRef = selectedLocalBranch
    let canEdit = canEditBranch(branchRef)
    let canMerge = canMergeBranch(branchRef)

    Button("New branch...", systemImage: "plus") {
      coordinator.newBranch()
    }
    Button("Rename branch", systemImage: "pencil") {
      if let branchRef {
        coordinator.renameBranch(branchRef)
      }
    }
      .disabled(!canEdit)
    Button(command: .merge) {
      if let branchRef {
        coordinator.mergeBranch(branchRef)
      }
    }
      .disabled(!canMerge)
    Button("Delete branch", systemImage: "trash") {
      if let branchRef {
        coordinator.deleteBranch(branchRef)
      }
    }
      .disabled(!canEdit)
    if let branchRef,
       model.brancher.localBranch(named: branchRef)?.trackingBranch != nil {
      Button(.deleteBranchAndRemote, systemImage: "trash") {
        coordinator.deleteBranchAndRemote(branchRef)
      }
        .disabled(!canEdit)
    }
  }

  @ViewBuilder
  private func remotesActionMenu() -> some View
  {
    Button("New remote...", systemImage: "plus") {
      coordinator.newRemote()
    }

    switch listSelection {
      case .remote(let remoteName):
        remoteActionItems(for: remoteName)
      case .remoteBranch(let ref):
        remoteBranchActionItems(for: ref)
      default:
        EmptyView()
    }
  }

  @ViewBuilder
  private func tagsActionMenu() -> some View
  {
    Button(.delete, systemImage: "trash", role: .destructive) {
      if case let .tag(tagRef)? = listSelection {
        coordinator.deleteTag(tagRef)
      }
    }
      .disabled(tagSelection == nil)
  }

  @ViewBuilder
  private func stashesActionMenu() -> some View
  {
    let topStash = model.items.firstStashID

    switch listSelection {
      case .stash(let stashID):
        Button(.pop, systemImage: "arrow.up.square.fill") {
          coordinator.popStash(stashID)
        }
        Button(.apply, systemImage: "arrow.up.square") {
          coordinator.applyStash(stashID)
        }
        Button(.drop, systemImage: "trash") {
          coordinator.dropStash(stashID)
        }
      default:
        Button("Pop top stash", systemImage: "arrow.up.square.fill") {
          if let topStash {
            coordinator.popStash(topStash)
          }
        }
          .disabled(topStash == nil)
        Button("Apply top stash", systemImage: "arrow.up.square") {
          if let topStash {
            coordinator.applyStash(topStash)
          }
        }
          .disabled(topStash == nil)
        Button("Drop top stash", systemImage: "trash") {
          if let topStash {
            coordinator.dropStash(topStash)
          }
        }
          .disabled(topStash == nil)
    }
  }

  @ViewBuilder
  private func submodulesActionMenu() -> some View
  {
    let name = selectedSubmodule

    Button("Show in Finder", systemImage: "finder") {
      if let name {
        coordinator.showSubmoduleInFinder(name)
      }
    }
      .disabled(name == nil)
    Button("Update", systemImage: "arrow.clockwise") {
      if let name {
        coordinator.updateSubmodule(name)
      }
    }
      .disabled(name == nil)
  }

  @ViewBuilder
  private func branchContextMenu(for ref: LocalBranchRefName) -> some View
  {
    if ref != model.brancher.currentBranch {
      Button(command: .checkOut) { coordinator.checkoutBranch(ref) }
        .axid(.BranchPopup.checkOut)
    }
    Button(command: .rename) { coordinator.renameBranch(ref) }
      .axid(.BranchPopup.rename)
      .disabled(!canEditBranch(ref))
    Button(command: .merge) { coordinator.mergeBranch(ref) }
      .axid(.BranchPopup.merge)
      .disabled(!canMergeBranch(ref))
    Divider()
    Button(command: .delete, role: .destructive) {
      coordinator.deleteBranch(ref)
    }
      .axid(.BranchPopup.delete)
      .disabled(!canEditBranch(ref))
    if model.brancher.localBranch(named: ref)?.trackingBranch != nil {
      Button(.deleteBranchAndRemote, systemImage: "trash", role: .destructive) {
        coordinator.deleteBranchAndRemote(ref)
      }
        .disabled(!canEditBranch(ref))
    }
  }

  @ViewBuilder
  private func remoteContextMenu(for name: String) -> some View
  {
    remoteActionItems(for: name)
  }

  @ViewBuilder
  private func remoteActionItems(for name: String) -> some View
  {
    Button(.rename, systemImage: "pencil") {
      coordinator.renameRemote(name)
    }
    Button(.edit, systemImage: "slider.horizontal.3") {
      coordinator.editRemote(name)
    }
    Button(.delete, systemImage: "trash", role: .destructive) {
      coordinator.deleteRemote(name)
    }
    Button(.copyURL, systemImage: "document.on.document") {
      coordinator.copyRemoteURL(name)
    }
  }

  @ViewBuilder
  private func remoteBranchContextMenu(for ref: RemoteBranchRefName) -> some View
  {
    remoteBranchActionItems(for: ref)
  }

  @ViewBuilder
  private func remoteBranchActionItems(for ref: RemoteBranchRefName) -> some View
  {
    Button(.createTrackingBranch, systemImage: "plus.circle") {
      coordinator.createTrackingBranch(ref)
    }
      .axid(.RemoteBranchPopup.createTracking)
    Button(command: .merge) {
      coordinator.mergeRemoteBranch(ref)
    }
  }

  @ViewBuilder
  private func tagContextMenu(for tagRef: TagRefName) -> some View
  {
    Button(.delete, systemImage: "trash", role: .destructive) {
      coordinator.deleteTag(tagRef)
    }
      .axid(.TagPopup.delete)
  }

  @ViewBuilder
  private func stashContextMenu(for stashID: GitOID) -> some View
  {
    Button(.pop, systemImage: "arrow.up.square.fill") {
      coordinator.popStash(stashID)
    }
    Button(.apply, systemImage: "arrow.up.square") {
      coordinator.applyStash(stashID)
    }
    Button(.drop, systemImage: "trash") {
      coordinator.dropStash(stashID)
    }
  }

  @ViewBuilder
  private func submoduleContextMenu(for name: String) -> some View
  {
    Button("Show in Finder", systemImage: "finder") {
      coordinator.showSubmoduleInFinder(name)
    }
    Button("Update", systemImage: "arrow.clockwise") {
      coordinator.updateSubmodule(name)
    }
  }

  private var selectedLocalBranch: LocalBranchRefName?
  {
    guard case let .localBranch(ref)? = listSelection
    else { return nil }
    return ref
  }

  private var tagSelection: TagRefName?
  {
    guard case let .tag(ref)? = listSelection
    else { return nil }
    return ref
  }

  private var selectedSubmodule: String?
  {
    guard case let .submodule(name)? = listSelection
    else { return nil }
    return name
  }

  private func canEditBranch(_ branchRef: LocalBranchRefName?) -> Bool
  {
    branchRef != nil && branchRef != model.brancher.currentBranch
  }

  private func canMergeBranch(_ branchRef: LocalBranchRefName?) -> Bool
  {
    branchRef != nil && branchRef != model.brancher.currentBranch
  }

  @ViewBuilder
  private func upstreamIndicator(for branch: BranchListItem) -> some View
  {
    switch branch.trackingIndicator {
      case .none, .network:
        EmptyView()
      case .statusBadge(let text):
        StatusBadge(text, axid: .Sidebar.trackingStatus)
    }
  }

  private func tagInfoBinding(for info: TagInfoModel) -> Binding<Bool>
  {
    Binding(
        get: { coordinator.presentedTagInfo?.id == info.id },
        set: { isPresented in
          if isPresented {
            coordinator.showTagInfo(info)
          }
          else if coordinator.presentedTagInfo?.id == info.id {
            coordinator.dismissTagInfo()
          }
        })
  }
}

private struct StagingRow: View
{
  @ObservedObject var countModel: WorkspaceStatusCountModel
  let isSelected: Bool

  var body: some View
  {
    let counts = countModel.counts
    let hasPendingChanges =
        counts.staged > 0 || counts.unstaged > 0
    let highlightColor: Color =
        hasPendingChanges
        ? (isSelected ? .white : .accentColor)
        : .primary

    HStack(spacing: 4) {
      Image(systemName: "checklist")
        .frame(width: 16, alignment: .center)
        .foregroundStyle(highlightColor)
      Text(UIString.staging.rawValue)
        .fontWeight(hasPendingChanges ? .bold : .regular)
        .foregroundStyle(highlightColor)
        .axid(.Sidebar.stagingCell)
      Spacer()
      if hasPendingChanges {
        WorkspaceStatusBadge(
            unstagedCount: counts.unstaged,
            stagedCount: counts.staged,
            highlighted: !isSelected)
      }
    }
      .contentShape(Rectangle())
      .listRowSeparator(.hidden)
  }
}

private extension Array where Element == PathTreeNode<SidebarTreeItem>
{
  var firstStashID: GitOID?
  {
    for item in self {
      switch item.item {
        case .stash(let stash):
          return stash.id
        default:
          if let children = item.children,
             let stash = children.firstStashID {
            return stash
          }
      }
    }
    return nil
  }
}

#if DEBUG
// For some reason NullFileStatusDetection isn't visible, even though
// calling this NullFileStatusDetection is an "invalid redeclaration"
private class NFSD: EmptyFileStatusDetection {}

#Preview
{
  let brancher = BranchListPreview.Brancher(localBranches: [
    "master",
    "feature/things",
    "someWork",
  ].map { .init(name: $0) })
  let manager = FakeRemoteManager(remoteNames: ["origin"])
  let publisher = NullRepositoryPublishing()
  let stasher = StashListPreview.PreviewStashing(["one", "two", "three"])
  let tagger = TagListPreview.Tagger(tagList: [
    "someWork",
    "releases/v1.0",
    "releases/v1.1",
  ].map { .init(name: $0) })
  let subManager = SubmoduleListPreview.SubmoduleManager()
  let referencer = BranchListPreview.CommitReferencer()
  let model = SidebarViewModel(brancher: brancher,
                               detector: NFSD(),
                               remoteManager: manager,
                               referencer: referencer,
                               publisher: publisher,
                               stasher: stasher,
                               submoduleManager: subManager,
                               tagger: tagger,
                               workspaceCountModel: .init())

  TabbedSidebar(model: model)
    .environmentObject(SidebarCoordinator())
    .environmentObject(BranchAccessoryStore())
}
#endif
