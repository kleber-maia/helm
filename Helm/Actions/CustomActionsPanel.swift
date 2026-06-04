import SwiftUI

class CustomActionsModel: ObservableObject, Validating
{
  @Published var actions: [CustomAction]
  @Published var selectedID: UUID?

  @Published var isValid: Bool = true

  init(actions: [CustomAction] = [])
  {
    self.actions = actions
    self.selectedID = actions.first?.id
  }

  var selectedAction: CustomAction?
  {
    get
    {
      guard let id = selectedID
      else { return nil }
      return actions.first { $0.id == id }
    }
    set
    {
      guard let newValue,
            let index = actions.firstIndex(
                where: { $0.id == newValue.id })
      else { return }
      actions[index] = newValue
    }
  }

  func addAction()
  {
    let action = CustomAction(name: "New Action")

    actions.append(action)
    selectedID = action.id
  }

  func deleteSelected()
  {
    guard let id = selectedID
    else { return }

    actions.removeAll { $0.id == id }
    selectedID = actions.first?.id
  }

  func moveActions(from source: IndexSet,
                   to destination: Int)
  {
    actions.move(fromOffsets: source, toOffset: destination)
  }
}

struct CustomActionsPanel: DataModelView
{
  @ObservedObject var model: CustomActionsModel
  @State private var showSymbolPicker = false

  init(model: CustomActionsModel)
  {
    self.model = model
  }

  var body: some View
  {
    HSplitView {
      actionList
        .frame(minWidth: 160, maxWidth: 200)
      detailEditor
        .frame(minWidth: 250)
    }
    .frame(width: 500, height: 300)
  }

  private var actionList: some View
  {
    VStack(spacing: 0) {
      List(selection: $model.selectedID) {
        ForEach(Array(model.actions.enumerated()),
                id: \.element.id) {
          index, action in
          HStack(spacing: 6) {
            Image(systemName: action.symbolName)
              .frame(width: 16)
            Text(action.name.isEmpty
                 ? "Untitled" : action.name)
            if index == 0 {
              Spacer()
              Text("Default")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          .tag(action.id)
        }
        .onMove(perform: model.moveActions)
      }
      .listStyle(.bordered)

      HStack(spacing: 1) {
        Button(action: model.addAction) {
          Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .frame(width: 24, height: 20)

        Button(action: model.deleteSelected) {
          Image(systemName: "minus")
        }
        .buttonStyle(.borderless)
        .disabled(model.selectedID == nil)
        .frame(width: 24, height: 20)

        Spacer()
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
    }
  }

  @ViewBuilder
  private var detailEditor: some View
  {
    if let action = model.selectedAction {
      let binding = Binding<CustomAction>(
        get: { action },
        set: { model.selectedAction = $0 }
      )

      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Button {
            showSymbolPicker.toggle()
          } label: {
            Image(systemName: action.symbolName)
              .font(.title2)
              .frame(width: 32, height: 32)
              .background(Color.secondary.opacity(0.1))
              .cornerRadius(6)
          }
          .buttonStyle(.plain)
          .help("Choose symbol")
          .popover(isPresented: $showSymbolPicker) {
            SymbolGridPicker(
                selection: binding.symbolName,
                isPresented: $showSymbolPicker)
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Symbol")
              .font(.caption)
              .foregroundStyle(.secondary)
            TextField("terminal",
                      text: binding.symbolName)
              .textFieldStyle(.roundedBorder)
          }
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("Name")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField("Action name",
                    text: binding.name)
            .textFieldStyle(.roundedBorder)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("Commands")
            .font(.caption)
            .foregroundStyle(.secondary)
          ZStack(alignment: .topLeading) {
            TextEditor(text: binding.commands)
              .font(.system(.body, design: .monospaced))
              .frame(minHeight: 60, maxHeight: 120)

            if action.commands.isEmpty {
              Text("echo \"Hello World\"\ngit status")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 7)
                .allowsHitTesting(false)
            }
          }
          .overlay(
            RoundedRectangle(cornerRadius: 4)
              .stroke(Color.secondary.opacity(0.3),
                      lineWidth: 1)
          )
        }

        Spacer()
      }
      .padding(12)
    }
    else {
      VStack {
        Spacer()
        Text("No action selected")
          .foregroundStyle(.secondary)
        Spacer()
      }
      .frame(maxWidth: .infinity)
    }
  }
}
