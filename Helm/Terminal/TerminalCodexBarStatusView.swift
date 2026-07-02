import AppKit

final class TerminalCodexBarStatusView: NSView
{
  private let sessionMeter: TerminalUsageMeterView
  private let weeklyMeter: TerminalUsageMeterView
  private let contentSpacing: CGFloat
  private let verticalInset: CGFloat
  private let horizontalInset: CGFloat
  private let meterMinimumWidth: CGFloat
  private var contentStack: NSStackView!
  private var resetTimer: Timer?

  init(font: NSFont,
       contentSpacing: CGFloat = 28,
       verticalInset: CGFloat = 4,
       horizontalInset: CGFloat = 0,
       meterMinimumWidth: CGFloat = 190)
  {
    self.contentSpacing = contentSpacing
    self.verticalInset = verticalInset
    self.horizontalInset = horizontalInset
    self.meterMinimumWidth = meterMinimumWidth
    self.sessionMeter = TerminalUsageMeterView(symbolName: "timer",
                                               font: font,
                                               resetStyle: .countdown,
                                               minimumWidth:
                                                meterMinimumWidth)
    self.weeklyMeter = TerminalUsageMeterView(symbolName: "calendar",
                                              font: font,
                                              resetStyle: .relative,
                                              minimumWidth:
                                                meterMinimumWidth)
    super.init(frame: .zero)
    configure()
  }

  required init?(coder: NSCoder)
  {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    self.contentSpacing = 28
    self.verticalInset = 4
    self.horizontalInset = 0
    self.meterMinimumWidth = 190
    self.sessionMeter = TerminalUsageMeterView(symbolName: "timer",
                                               font: font,
                                               resetStyle: .countdown,
                                               minimumWidth: 190)
    self.weeklyMeter = TerminalUsageMeterView(symbolName: "calendar",
                                              font: font,
                                              resetStyle: .relative,
                                              minimumWidth: 190)
    super.init(coder: coder)
    configure()
  }

  func update(with status: CodexBarUsageStatus)
  {
    sessionMeter.update(with: status.session)
    weeklyMeter.update(with: status.weekly)
    invalidateIntrinsicContentSize()
  }

  override var intrinsicContentSize: NSSize
  {
    let contentWidth = contentStack?.fittingSize.width ??
        meterMinimumWidth * 2 + contentSpacing
    let width = contentWidth + horizontalInset * 2
    let height = max(
      TerminalUsageMeterView.intrinsicHeight + verticalInset * 2,
      24
    )

    return NSSize(width: width, height: height)
  }

  deinit
  {
    resetTimer?.invalidate()
  }

  private func configure()
  {
    translatesAutoresizingMaskIntoConstraints = false

    contentStack = NSStackView(views: [sessionMeter, weeklyMeter])

    contentStack.orientation = .horizontal
    contentStack.alignment = .centerY
    contentStack.distribution = .fill
    contentStack.spacing = contentSpacing
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contentStack)

    NSLayoutConstraint.activate([
      contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
      contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                            constant: horizontalInset),
      contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                             constant: -horizontalInset),
      contentStack.topAnchor.constraint(equalTo: topAnchor,
                                        constant: verticalInset),
      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor,
                                           constant: -verticalInset),
    ])

    resetTimer = Timer.scheduledTimer(withTimeInterval: 60,
                                      repeats: true) {
      [weak self] _ in
      self?.sessionMeter.refreshResetText()
      self?.weeklyMeter.refreshResetText()
    }
  }
}

private final class TerminalUsageMeterView: NSView
{
  enum ResetStyle
  {
    case countdown
    case relative
  }

  private let symbolView: NSImageView
  private let fixedFont: NSFont
  private let progressLabel = NSTextField(labelWithString: "")
  private let percentLabel = NSTextField(labelWithString: "")
  private let resetLabel = NSTextField(labelWithString: "")
  private let resetStyle: ResetStyle
  private let minimumWidth: CGFloat
  private var usageWindow: CodexBarUsageWindow?

  init(symbolName: String,
       font: NSFont,
       resetStyle: ResetStyle,
       minimumWidth: CGFloat)
  {
    let image = NSImage(systemSymbolName: symbolName,
                        accessibilityDescription: nil)

    self.symbolView = NSImageView(image: image ?? NSImage())
    self.fixedFont = font
    self.resetStyle = resetStyle
    self.minimumWidth = minimumWidth
    super.init(frame: .zero)
    configure()
  }

  required init?(coder: NSCoder)
  {
    let image = NSImage(systemSymbolName: "circle",
                        accessibilityDescription: nil)

    self.symbolView = NSImageView(image: image ?? NSImage())
    self.fixedFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    self.resetStyle = .relative
    self.minimumWidth = 190
    super.init(coder: coder)
    configure()
  }

  func update(with window: CodexBarUsageWindow)
  {
    self.usageWindow = window

    let percent = max(0, min(100, window.usedPercent))

    percentLabel.stringValue = "\(Int(percent.rounded()))% for"
    refreshResetText()
    progressLabel.stringValue = Self.progressText(percent: percent)
    progressLabel.textColor = window.hasEnoughRemainingQuota
        ? .systemGreen
        : .systemOrange
  }

  func refreshResetText()
  {
    guard let window = usageWindow
    else { return }

    resetLabel.stringValue = Self.resetText(for: window,
                                            style: resetStyle)
  }

  private func configure()
  {
    translatesAutoresizingMaskIntoConstraints = false

    let symbolConfig = NSImage.SymbolConfiguration(pointSize: fixedFont.pointSize,
                                                   weight: .regular)

    symbolView.symbolConfiguration = symbolConfig
    symbolView.contentTintColor = .labelColor
    symbolView.translatesAutoresizingMaskIntoConstraints = false

    progressLabel.font = fixedFont
    progressLabel.textColor = .systemGreen
    progressLabel.lineBreakMode = .byClipping

    percentLabel.font = fixedFont
    percentLabel.textColor = .secondaryLabelColor
    percentLabel.alignment = .right

    resetLabel.font = fixedFont
    resetLabel.textColor = .secondaryLabelColor
    resetLabel.lineBreakMode = .byTruncatingTail

    let stack = NSStackView(views: [
      symbolView,
      progressLabel,
      percentLabel,
      resetLabel,
    ])

    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    symbolView.setContentCompressionResistancePriority(.required,
                                                       for: .horizontal)
    progressLabel.setContentCompressionResistancePriority(.required,
                                                         for: .horizontal)
    percentLabel.setContentCompressionResistancePriority(.required,
                                                         for: .horizontal)
    resetLabel.setContentCompressionResistancePriority(.required,
                                                       for: .horizontal)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      symbolView.widthAnchor.constraint(equalToConstant: 16),
      symbolView.heightAnchor.constraint(equalToConstant: 16),
    ])

    if minimumWidth > 0 {
      widthAnchor.constraint(greaterThanOrEqualToConstant:
        minimumWidth).isActive = true
    }
  }

  private static func progressText(percent: Double) -> String
  {
    let filledCount = Int((percent / 100 * Double(progressCharacters)).rounded())
    let clampedFilled = max(0, min(progressCharacters, filledCount))
    let unfilledCount = progressCharacters - clampedFilled

    return String(repeating: filledCharacter, count: clampedFilled) +
        String(repeating: unfilledCharacter, count: unfilledCount)
  }

  private static func resetText(for window: CodexBarUsageWindow,
                                style: ResetStyle) -> String
  {
    if style == .countdown,
       let resetsAt = window.resetsAt {
      return countdownText(until: resetsAt)
    }

    guard let resetsAt = window.resetsAt
    else {
      if let resetDescription = window.resetDescription,
         !resetDescription.isEmpty {
        return resetDescription
      }
      return "unknown"
    }

    return relativeResetText(until: resetsAt)
  }

  /// Time remaining until `date`, expressed in whole days, or in whole
  /// hours when less than a day away. Rounding hours first lets a value
  /// like 23.9h roll cleanly up into "1d" instead of showing "24h".
  private static func relativeResetText(until date: Date) -> String
  {
    let remaining = max(0, date.timeIntervalSinceNow)
    let hours = Int((remaining / 3600).rounded())

    if hours < 24 {
      return "\(max(1, hours))h"
    }

    let days = Int((Double(hours) / 24).rounded())
    return "\(days)d"
  }

  private static func countdownText(until date: Date) -> String
  {
    let remaining = max(0, Int(date.timeIntervalSinceNow))
    let hours = remaining / 3600
    let minutes = (remaining % 3600) / 60

    if hours > 0 {
      return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
  }

  private static let progressCharacters = 8
  private static let filledCharacter = "🁢"
  private static let unfilledCharacter = "🂋"
  static let intrinsicHeight: CGFloat = 18
}
