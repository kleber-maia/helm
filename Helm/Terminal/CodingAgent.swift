import AppKit

enum CodingAgent: String, CaseIterable, Sendable
{
  case codex
  case claude
  case kimi
  case terminal

  var displayName: String
  {
    switch self {
      case .codex:    return "Codex"
      case .claude:   return "Claude"
      case .kimi:     return "Kimi"
      case .terminal: return "Terminal"
    }
  }

  var image: NSImage?
  {
    let baseImage: NSImage?

    switch self {
      case .codex:
        baseImage = NSImage(named: "codex-logo")
      case .claude:
        baseImage = NSImage(named: "claude-logo")
      case .kimi:
        baseImage = NSImage(named: "kimi-logo")
      case .terminal:
        baseImage = NSImage(systemSymbolName: "apple.terminal",
                            accessibilityDescription: displayName)
    }
    guard let image = baseImage?.copy() as? NSImage
    else { return baseImage }

    image.size = NSSize(width: 16, height: 16)
    if self != .terminal {
      image.isTemplate = true
    }
    return image
  }

  var launchCommand: String?
  {
    switch self {
      case .codex:    return "codex"
      case .claude:   return "claude"
      case .kimi:     return "kimi"
      case .terminal: return nil
    }
  }

  var codexBarProviderID: String?
  {
    switch self {
      case .codex, .claude, .kimi:
        return rawValue
      case .terminal:
        return nil
    }
  }

  var codexBarSource: String?
  {
    switch self {
      case .codex, .claude:
        return "oauth"
      case .kimi:
        // Kimi authenticates with an API key; let CodexBar auto-resolve
        // the source (which resolves to its API source).
        return nil
      case .terminal:
        return nil
    }
  }
}
