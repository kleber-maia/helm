import SwiftUI

/// List cell view used by local and remote branch lists.
struct BranchCell<Item: PathTreeData,
                  TrailingContent: View,
                  ContextMenuContent: View>: View
{
  let node: PathTreeNode<Item>
  let isCurrent: Bool
  let hasContextMenu: Bool
  @ViewBuilder
  let trailingContent: () -> TrailingContent
  @ViewBuilder
  let contextMenuContent: () -> ContextMenuContent

  var body: some View
  {
    if hasContextMenu {
      row.contextMenu(menuItems: contextMenuContent)
    }
    else {
      row
    }
  }

  @ViewBuilder
  private var row: some View
  {
    let branch = node.item

    HStack(spacing: 4) {
      if branch == nil {
        Image(systemName: "folder.fill")
          .frame(width: 16, alignment: .center)
      }
      else if isCurrent {
        Image("scm.branch")
          .fontWeight(.bold)
          .frame(width: 16, alignment: .center)
          .accessibilityElement()
          .axid(.Sidebar.currentBranchCheck)
      }
      branchTitle
      Spacer(minLength: 0)
      trailingContent()
    }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .listRowSeparator(.hidden)
      .selectionDisabled(branch == nil)
  }

  private var branchTitle: some View
  {
    Text(node.path.lastPathComponent)
      .font(.system(size: NSFont.systemFontSize,
                    weight: isCurrent ? .bold : .regular))
      .lineLimit(1)
      .truncationMode(.tail)
      .help(node.path.lastPathComponent)
      .padding(.horizontal, 4)
      .accessibilityIdentifier(isCurrent ? "currentBranch" : "branch")
  }

  init(node: PathTreeNode<Item>,
       isCurrent: Bool = false,
       @ViewBuilder trailingContent: @escaping () -> TrailingContent)
    where ContextMenuContent == EmptyView
  {
    self.node = node
    self.isCurrent = isCurrent
    self.hasContextMenu = false
    self.trailingContent = trailingContent
    self.contextMenuContent = { EmptyView() }
  }

  init(node: PathTreeNode<Item>,
       isCurrent: Bool = false,
       @ViewBuilder trailingContent: @escaping () -> TrailingContent,
       @ViewBuilder contextMenu: @escaping () -> ContextMenuContent)
  {
    self.node = node
    self.isCurrent = isCurrent
    self.hasContextMenu = true
    self.trailingContent = trailingContent
    self.contextMenuContent = contextMenu
  }
}

