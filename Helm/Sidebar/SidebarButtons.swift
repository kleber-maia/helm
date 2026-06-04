import SwiftUI
import AppKit

/// Borderless sidebar action menu button used in the filter bar and section
/// headers.
struct SidebarActionButton<Content: View>: View
{
  let content: () -> Content

  var body: some View
  {
    Menu(content: content, label: {
      Image(systemName: "ellipsis.circle")
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    })
    .menuStyle(.borderlessButton)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .tint(Color(nsColor: .secondaryLabelColor))
    .frame(width: 24)
  }

  init(@ViewBuilder content: @escaping () -> Content)
  {
    self.content = content
  }
}

struct SidebarBottomButton: View
{
  let systemImage: String
  let action: () -> Void

  var body: some View
  {
    Button(action: action, label: {
      Image(systemName: systemImage)
    }).buttonStyle(.plain).padding(.horizontal, 3)
  }
}
