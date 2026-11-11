import SwiftUI

private struct SidebarIconColorKey: EnvironmentKey {
  static let defaultValue: NSColor? = nil
}
private struct SidebarIconSelectedKey: EnvironmentKey {
  static let defaultValue = false
}
extension EnvironmentValues {
  var sidebarIconColor: NSColor? {
    get { self[SidebarIconColorKey.self] }
    set { self[SidebarIconColorKey.self] = newValue }
  }
  var sidebarIconSelected: Bool {
    get { self[SidebarIconSelectedKey.self] }
    set { self[SidebarIconSelectedKey.self] = newValue }
  }
}

/// Applies only to glyphs. Consumers outside the sidebar retain their styles.
private struct SidebarIconTint: ViewModifier {
  @Environment(\.sidebarIconColor) private var color
  @Environment(\.sidebarIconSelected) private var selected
  @Environment(\.isEnabled) private var enabled
  @Environment(\.colorScheme) private var scheme

  func body(content: Content) -> some View {
    if let color {
      content.symbolRenderingMode(.monochrome)
        .foregroundStyle(Color(nsColor: readable(color)).opacity(enabled ? 1 : 0.45))
    }
    else { content }
  }

  private func readable(_ original: NSColor) -> NSColor {
    var result = original
    let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
    appearance.performAsCurrentDrawingAppearance {
      let backgrounds: [NSColor] = selected
        ? [.selectedContentBackgroundColor, .unemphasizedSelectedContentBackgroundColor]
        : [.windowBackgroundColor]
      func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ value: CGFloat) -> CGFloat {
          value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return linear(rgb.redComponent) * 0.2126 + linear(rgb.greenComponent) * 0.7152 + linear(rgb.blueComponent) * 0.0722
      }
      func contrast(_ color: NSColor) -> CGFloat {
        let value = luminance(color)
        return backgrounds.map { background in
          let other = luminance(background)
          return (max(value, other) + 0.05) / (min(value, other) + 0.05)
        }.min() ?? 1
      }
      guard contrast(original) < 3 else { return }
      let target: NSColor = contrast(.white) > contrast(.black) ? .white : .black
      for fraction in stride(from: 0.1, through: 1.0, by: 0.1) {
        let candidate = original.blended(withFraction: fraction, of: target) ?? target
        result = candidate
        if contrast(candidate) >= 3 { break }
      }
    }
    return result
  }
}
extension View {
  func sidebarIconTint() -> some View { modifier(SidebarIconTint()) }
}
