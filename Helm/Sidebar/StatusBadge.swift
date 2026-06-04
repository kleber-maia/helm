import SwiftUI

struct StatusBadge: View
{
  let text: String
  let tint: Color?
  let axid: AXID?

  var body: some View
  {
    Text(text)
      .foregroundStyle(tintForeground)
      .padding(EdgeInsets(top: 1, leading: 5,
                          bottom: 1, trailing: 5))
      .background(tint ?? Color(nsColor: .controlColor))
      .clipShape(.capsule)
      .font(.system(size: 10))
      .axid(axid ?? .init(rawValue: ""))
  }

  private var tintForeground: Color
  {
    guard tint != nil
    else { return Color(nsColor: .controlTextColor) }

    let accent = NSColor.controlAccentColor
    var brightness: CGFloat = 0

    accent.usingColorSpace(.sRGB)?
      .getHue(nil, saturation: nil,
              brightness: &brightness, alpha: nil)
    return brightness > 0.7 ? .black : .white
  }

  init(_ text: String, tint: Color? = nil,
       axid: AXID? = nil)
  {
    self.text = text
    self.tint = tint
    self.axid = axid
  }
}

struct WorkspaceStatusBadge: View
{
  let unstagedCount, stagedCount: Int
  var highlighted = false

  var body: some View
  {
    StatusBadge("\(unstagedCount) ▸ \(stagedCount)",
                tint: highlighted ? Color.accentColor : nil,
                axid: .Sidebar.workspaceStatus)
  }
}
