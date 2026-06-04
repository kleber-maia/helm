import SwiftUI

/// A partial re-implementation of `OutlineGroup` with the addition of a binding
/// to read and write the set of expanded items. Renders as a flat list to
/// prevent SwiftUI from applying automatic outline indentation.
struct RecursiveDisclosureGroup<Data, ID, TagValue, RowContent>: View
  where Data: RandomAccessCollection, ID: Hashable,
        TagValue: Hashable, RowContent: View
{
  typealias DataElement = Data.Element

  let data: Data
  let id: KeyPath<DataElement, ID>
  let children: KeyPath<DataElement, Data?>
  let expandedItems: Binding<Set<ID>>
  let tagForElement: (DataElement) -> TagValue?
  let content: (DataElement) -> RowContent

  var body: some View
  {
    let flat = flattenedRows(data: data, level: 0)

    ForEach(flat, id: \.id) {
      (row) in
      let rowView = HStack(spacing: 0) {
        content(row.element)
        Spacer(minLength: 4)
        if row.hasChildren {
          let binding = expandedItems.binding(for: row.id)

          Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.tertiary)
            .rotationEffect(binding.wrappedValue
                            ? .degrees(90) : .zero)
            .animation(.easeInOut(duration: 0.15),
                       value: binding.wrappedValue)
            .onTapGesture { binding.wrappedValue.toggle() }
        }
      }
        .padding(.leading, CGFloat(row.level) * 12)
        .listRowInsets(EdgeInsets())

      tagValue(rowView, row.tagValue)
    }
  }

  @ViewBuilder
  private func tagValue<V: View>(_ view: V,
                                  _ tag: TagValue?) -> some View
  {
    if let tag {
      view.tag(tag)
    }
    else {
      view
    }
  }

  private struct FlatRow: Identifiable {
    let element: DataElement
    let id: ID
    let level: Int
    let hasChildren: Bool
    let tagValue: TagValue?
  }

  private func flattenedRows(data: Data,
                              level: Int) -> [FlatRow]
  {
    var result = [FlatRow]()

    for element in data {
      let itemID = element[keyPath: id]
      let sub = element[keyPath: children]
      let hasChildren = sub != nil

      result.append(FlatRow(element: element, id: itemID,
                            level: level,
                            hasChildren: hasChildren,
                            tagValue: tagForElement(element)))

      if let sub, expandedItems.wrappedValue.contains(itemID) {
        result.append(contentsOf:
            flattenedRows(data: sub, level: level + 1))
      }
    }
    return result
  }

  init(_ data: Data,
       id: KeyPath<DataElement, ID>,
       children: KeyPath<DataElement, Data?>,
       expandedItems: Binding<Set<ID>>,
       tagForElement: @escaping (DataElement) -> TagValue?,
       @ViewBuilder content: @escaping (DataElement) -> RowContent)
  {
    self.data = data
    self.id = id
    self.children = children
    self.expandedItems = expandedItems
    self.tagForElement = tagForElement
    self.content = content
  }
}

extension RecursiveDisclosureGroup
{
  init<Item: PathTreeData>(
      _ data: Data,
      expandedItems: Binding<Set<String>>,
      tagForElement: @escaping (DataElement) -> TagValue?,
      @ViewBuilder content: @escaping (DataElement) -> RowContent)
    where Data == [PathTreeNode<Item>], ID == String
  {
    self.data = data
    self.id = \.path
    self.children = \.children
    self.expandedItems = expandedItems
    self.tagForElement = tagForElement
    self.content = content
  }

  /// Convenience init without tags (for standalone lists).
  init<Item: PathTreeData>(
      _ data: Data,
      expandedItems: Binding<Set<String>>,
      @ViewBuilder content: @escaping (DataElement) -> RowContent)
    where Data == [PathTreeNode<Item>], ID == String,
          TagValue == String
  {
    self.data = data
    self.id = \.path
    self.children = \.children
    self.expandedItems = expandedItems
    self.tagForElement = { _ in nil }
    self.content = content
  }
}

#if DEBUG
struct RDGPreview: View
{
  let data: [PathTreeNode<String>]
  let folderPaths: [String]
  @State var expandedItems: Set<String> = []

  var body: some View
  {
    List {
      Section("RecursiveDisclosureGroup") {
        RecursiveDisclosureGroup(data, expandedItems: $expandedItems,
                                 tagForElement: { _ in nil as String? }) {
          nodeLabel($0)
        }
      }
      Section("External toggles") {
        ForEach(folderPaths, id: \.self) {
          (path) in
          Toggle(path, isOn: .init {
            expandedItems.contains(path)
          } set: {
            if $0 {
              expandedItems.insert(path)
            }
            else {
              expandedItems.remove(path)
            }
          })
        }
      }
      Section("OutlineGroup") {
        OutlineGroup(data, id: \.path, children: \.children) {
          nodeLabel($0)
        }
      }
    }
  }

  func nodeLabel(_ node: PathTreeNode<String>) -> some View
  {
    Label {
      Text(node.path.lastPathComponent)
    } icon: {
      Image(systemName: node.children == nil ? "doc" : "folder")
    }
  }

  init(_ paths: [String])
  {
    self.data = PathTreeNode.makeHierarchy(from: paths)
    self.folderPaths = paths
  }
}

#Preview {
  RDGPreview([
    "folder",
    "folder/item",
    "folder/folder2",
    "folder/folder2/item2",
  ])
}
#endif
