import SwiftUI

/// A searchable grid of common SF Symbols presented
/// in a popover.
struct SymbolGridPicker: View
{
  @Binding var selection: String
  @Binding var isPresented: Bool
  @State private var searchText = ""

  private let columns = Array(
      repeating: GridItem(.fixed(32), spacing: 4),
      count: 8)

  private var filtered: [String]
  {
    if searchText.isEmpty {
      return Self.symbols
    }
    let query = searchText.lowercased()

    return Self.symbols.filter {
      $0.lowercased().contains(query)
    }
  }

  var body: some View
  {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search symbols", text: $searchText)
          .textFieldStyle(.plain)
      }
      .padding(8)

      Divider()

      ScrollView {
        if filtered.isEmpty {
          Text("No matches")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
        }
        else {
          LazyVGrid(columns: columns, spacing: 4) {
            ForEach(filtered, id: \.self) {
              symbol in
              Button {
                selection = symbol
                isPresented = false
              } label: {
                Image(systemName: symbol)
                  .font(.system(size: 16))
                  .frame(width: 28, height: 28)
                  .background(
                    selection == symbol
                        ? Color.accentColor.opacity(0.2)
                        : Color.clear)
                  .cornerRadius(4)
              }
              .buttonStyle(.plain)
              .help(symbol)
            }
          }
          .padding(8)
        }
      }
    }
    .frame(width: 300, height: 280)
  }

  // swiftlint:disable line_length
  static let symbols: [String] = [
    // Developer & Build
    "terminal", "terminal.fill",
    "hammer", "hammer.fill",
    "wrench", "wrench.fill",
    "wrench.and.screwdriver",
    "wrench.and.screwdriver.fill",
    "gearshape", "gearshape.fill",
    "gearshape.2", "gearshape.2.fill",
    "swift", "curlybraces",

    // Play & Control
    "play", "play.fill",
    "play.circle", "play.circle.fill",
    "stop", "stop.fill",
    "pause", "pause.fill",
    "forward", "forward.fill",
    "bolt", "bolt.fill",
    "bolt.circle", "bolt.circle.fill",
    "power", "restart",

    // Arrows & Transfer
    "arrow.triangle.2.circlepath",
    "arrow.clockwise",
    "arrow.counterclockwise",
    "arrow.up.circle", "arrow.up.circle.fill",
    "arrow.down.circle", "arrow.down.circle.fill",
    "arrow.right.circle", "arrow.right.circle.fill",
    "square.and.arrow.up",
    "square.and.arrow.down",

    // Files & Folders
    "doc", "doc.fill",
    "doc.text", "doc.text.fill",
    "folder", "folder.fill",
    "trash", "trash.fill",
    "archivebox", "archivebox.fill",

    // Cloud & Network
    "cloud", "cloud.fill",
    "cloud.bolt", "cloud.bolt.fill",
    "icloud.and.arrow.up",
    "icloud.and.arrow.down",
    "network", "globe",
    "antenna.radiowaves.left.and.right",

    // Git & Source Control
    "arrow.triangle.branch",
    "arrow.triangle.merge",
    "arrow.triangle.pull",
    "tuningfork",
    "point.3.filled.connected.trianglepath.dotted",

    // Checkmark & Status
    "checkmark", "checkmark.circle",
    "checkmark.circle.fill",
    "xmark", "xmark.circle",
    "xmark.circle.fill",
    "exclamationmark.triangle",
    "exclamationmark.triangle.fill",
    "exclamationmark.circle",
    "info.circle", "info.circle.fill",
    "questionmark.circle",

    // Communication
    "bell", "bell.fill",
    "envelope", "envelope.fill",
    "message", "message.fill",
    "bubble.left", "bubble.left.fill",

    // Security
    "lock", "lock.fill",
    "lock.open", "lock.open.fill",
    "key", "key.fill",
    "shield", "shield.fill",
    "shield.checkered",

    // Data & Storage
    "externaldrive", "externaldrive.fill",
    "internaldrive", "internaldrive.fill",
    "opticaldiscsymbol", "cylinder",
    "cylinder.fill",
    "tray", "tray.fill",
    "tray.and.arrow.up", "tray.and.arrow.down",

    // Misc Tools
    "scissors", "paintbrush",
    "paintbrush.fill", "eyedropper",
    "wand.and.stars",
    "sparkles", "star", "star.fill",
    "flag", "flag.fill",
    "tag", "tag.fill",
    "bookmark", "bookmark.fill",
    "pin", "pin.fill",
    "paperclip",
    "link",

    // Shapes & Symbols
    "circle", "circle.fill",
    "square", "square.fill",
    "triangle", "triangle.fill",
    "diamond", "diamond.fill",
    "hexagon", "hexagon.fill",
    "heart", "heart.fill",
    "flame", "flame.fill",
    "leaf", "leaf.fill",
    "drop", "drop.fill",
    "snowflake", "ant",
    "ladybug", "hare",

    // Devices
    "desktopcomputer", "laptopcomputer",
    "display", "server.rack",

    // Text & Code
    "text.alignleft", "text.aligncenter",
    "list.bullet", "list.number",
    "chevron.left.forwardslash.chevron.right",
    "number", "textformat",
  ]
  // swiftlint:enable line_length
}
