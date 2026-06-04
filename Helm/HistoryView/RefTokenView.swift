import Cocoa

final class RefTokenView: NSView
{
  var text: String = ""
  { didSet { invalidateIntrinsicContentSize() } }
  var type: RefType = .unknown
  var graphColor: NSColor?

  override var intrinsicContentSize: NSSize
  {
    let size = (text as NSString).size(withAttributes:
          [.font: NSFont.refLabelFont])

    return NSSize(width: size.width + 12, height: 18)
  }

  override var firstBaselineOffsetFromTop: CGFloat
  {
    // 2pt top inset (capsuleRect) + font ascender aligns the
    // baseline with the adjacent label field.
    2 + NSFont.refLabelFont.ascender
  }

  override func contentHuggingPriority(
      for orientation: NSLayoutConstraint.Orientation)
    -> NSLayoutConstraint.Priority
  {
    return .required
  }

  override func contentCompressionResistancePriority(
      for orientation: NSLayoutConstraint.Orientation)
    -> NSLayoutConstraint.Priority
  {
    return .required
  }

  override func draw(_ dirtyRect: NSRect)
  {
    let path = self.makePath()
    let fillColor: NSColor
    let fgColor: NSColor

    if let graphColor = self.graphColor {
      fillColor = graphColor.blended(withFraction: 0.35,
                                     of: .windowBackgroundColor)
                  ?? graphColor
      fgColor = fillColor.contrastingTextColor
    }
    else {
      let active = type == .activeBranch
      let strokeColor = type.strokeColor.withAlphaComponent(
          LiquidGlassAccessibility.shouldIncreaseContrast
              ? 0.9 : 0.55)

      fillColor = type.surfaceColor
      fgColor = .refTokenText(active ? .active : .normal)

      fillColor.setFill()
      path.fill()
      path.lineWidth = active ? 1.2 : 0.8
      strokeColor.setStroke()
      path.stroke()

      drawText(fgColor: fgColor)
      return
    }

    fillColor.setFill()
    path.fill()

    drawText(fgColor: fgColor)
  }

  private func drawText(fgColor: NSColor)
  {
    let paragraphStyle = NSParagraphStyle.default.mutableCopy()
                         as! NSMutableParagraphStyle

    paragraphStyle.alignment = .center
    paragraphStyle.lineBreakMode = .byTruncatingMiddle

    let attributes: [NSAttributedString.Key: Any] = [
          .font: NSFont.refLabelFont,
          .paragraphStyle: paragraphStyle,
          .foregroundColor: fgColor]
    let attrText = NSMutableAttributedString(string: text,
                                             attributes: attributes)

    if let slashIndex = text.lastIndex(of: "/") {
      let pathRange = NSRange(text.startIndex...slashIndex,
                              in: text)

      attrText.addAttribute(.foregroundColor,
                            value: fgColor.withAlphaComponent(0.6),
                            range: pathRange)
    }

    attrText.draw(in: capsuleRect())
  }

  /// The rect used for both the capsule background and text layout.
  private func capsuleRect() -> NSRect
  {
    bounds.insetBy(dx: 0, dy: 2)
  }

  private func makePath() -> NSBezierPath
  {
    let rect = capsuleRect()

    guard !rect.isEmpty
    else { return .init(rect: .zero) }

    if graphColor != nil {
      let radius = rect.size.height / 2

      return NSBezierPath(roundedRect: rect,
                          xRadius: radius, yRadius: radius)
    }

    // Fallback: original shapes with stroke inset
    let strokeRect = rect.insetBy(dx: 0.5, dy: 0.5)

    switch type {
      case .branch, .activeBranch:
        let radius = strokeRect.size.height / 2

        return NSBezierPath(roundedRect: strokeRect,
                            xRadius: radius, yRadius: radius)

      case .tag:
        let path = NSBezierPath()
        let cornerInset: CGFloat = 5
        let top = strokeRect.origin.y
        let left = strokeRect.origin.x
        let bottom = top + strokeRect.size.height
        let right = left + strokeRect.size.width
        let leftInset = left + cornerInset
        let rightInset = right - cornerInset
        let middle = top + strokeRect.size.height / 2

        path.move(to: NSPoint(x: leftInset, y: top))
        path.line(to: NSPoint(x: rightInset, y: top))
        path.line(to: NSPoint(x: right, y: middle))
        path.line(to: NSPoint(x: rightInset, y: bottom))
        path.line(to: NSPoint(x: leftInset, y: bottom))
        path.line(to: NSPoint(x: left, y: middle))
        path.close()
        return path

      default:
        return NSBezierPath(rect: strokeRect)
    }
  }
}

extension NSFont
{
  static var refLabelFont: NSFont { labelFont(ofSize: 11) }
}
