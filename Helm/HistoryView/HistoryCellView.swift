import Cocoa

/// Cell view that draws the graph lines next to the text.
final class HistoryCellView: NSTableCellView
{
  private var entry: CommitEntry<GitCommit>!
  private var currentBranch: LocalBranchRefName?
  private var refs = [String]()
  private(set) var popoverMessage: String?

  var mutex: NSRecursiveLock!

  static let lineColors: [NSColor] = [
      NSColor(calibratedRed: 0.231, green: 0.510, blue: 0.965, alpha: 1.0),  // blue
      NSColor(calibratedRed: 0.659, green: 0.333, blue: 0.969, alpha: 1.0),  // purple
      NSColor(calibratedRed: 0.925, green: 0.282, blue: 0.600, alpha: 1.0),  // pink
      NSColor(calibratedRed: 0.941, green: 0.353, blue: 0.353, alpha: 1.0),  // red
      NSColor(calibratedRed: 0.941, green: 0.576, blue: 0.231, alpha: 1.0),  // orange
      NSColor(calibratedRed: 0.961, green: 0.835, blue: 0.278, alpha: 1.0),  // yellow
      NSColor(calibratedRed: 0.486, green: 0.827, blue: 0.420, alpha: 1.0),  // green
      NSColor(calibratedRed: 0.627, green: 0.627, blue: 0.627, alpha: 1.0),  // gray
      ]

  enum DisplayMode
  {
    case refsOnly, titleGraph, all, titleOnly, graphOnly

    var showRefs: Bool { self == .all || self == .refsOnly }
    var showTitle: Bool { self == .all || self == .titleGraph || self == .titleOnly }
    var showGraph: Bool { self == .all || self == .titleGraph || self == .graphOnly }
  }

  enum Widths
  {
    static let line: CGFloat = 2.0
    static let column: CGFloat = 8.0
  }

  enum Margins
  {
    static let left: CGFloat = 4.0
    static let text: CGFloat = 4.0
  }
  
  // Don't use NSTableCellView.textField
  // because the system messes with the colors
  @IBOutlet weak var labelField: NSTextField?
  @IBOutlet weak var stackView: NSStackView!
  @IBOutlet var stackViewInset: NSLayoutConstraint!

  override func awakeFromNib()
  {
    super.awakeFromNib()

    wantsLayer = true
    layer?.masksToBounds = false

    labelField?.usesSingleLineMode = true
    labelField?.lineBreakMode = .byTruncatingTail
    labelField?.allowsExpansionToolTips = true
  }

  var displayMode: DisplayMode = .all
  { didSet { updateConstraints() } }

  var deemphasized: Bool = false
  { didSet { updateTextColor() } }
  
  override var backgroundStyle: NSView.BackgroundStyle
  { didSet { updateTextColor() } }

  func updateTextColor()
  {
    let color: NSColor

    switch backgroundStyle {
      case .normal:
        color = deemphasized ? .disabledControlTextColor : .textColor
      case .emphasized:
        color = .alternateSelectedControlTextColor
      default:
        color = .textColor
    }
    labelField?.textColor = color
  }
  
  private func setLabel(_ message: String)
  {
    guard let labelField = self.labelField
    else { return }

    if let returnRange = message.rangeOfCharacter(from: .newlines),
       returnRange.upperBound < message.endIndex {
      let text = String(message.prefix(upTo: returnRange.lowerBound))

      labelField.stringValue = text
      popoverMessage = message
          .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    else {
      labelField.stringValue = message
      popoverMessage = nil
    }
  }

  func configure(entry: CommitEntry<GitCommit>,
                 repository: any CommitReferencing,
                 currentBranch: LocalBranchRefName?)
  {
    self.currentBranch = currentBranch
    refs = repository.refs(at: entry.commit.id)
    setLabel(entry.commit.message ?? "(no message)")
    self.entry = entry

    var views: [NSView] = []

    if displayMode.showRefs {
      let graphColor: NSColor? = entry.dotColorIndex.map {
        HistoryCellView.lineColors[
            Int($0) % HistoryCellView.lineColors.count]
      }

      let localBranchNames = refs.compactMap { ref -> String? in
        guard let (typeName, name) = ref.splitRefName(),
              typeName == "refs/heads/"
        else { return nil }
        return name
      }

      views.append(contentsOf: refs.reversed().map {
        (ref) -> NSView in
        let view = RefTokenView()

        if let (typeName, name) = ref.splitRefName() {
          var displayName = name
          if typeName == "refs/remotes/",
             let remoteBranch = RemoteBranchRefName(rawValue: ref),
             localBranchNames.contains(remoteBranch.localName) {
            displayName = remoteBranch.remoteName
          }
          view.text = displayName
          view.type = RefType(refName: ref,
                              currentBranch: currentBranch?.name ?? "")
          view.graphColor = graphColor
        }
        return view
      })
    }
    if displayMode.showTitle,
       let labelField = self.labelField {
      views.append(labelField)
    }

    if displayMode == .refsOnly {
      // Right-align refs by adding an expanding spacer
      let spacer = NSView()
      spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
      views.insert(spacer, at: 0)
      stackView.setViews(views, in: .leading)
    }
    else {
      stackView.setViews(views, in: .leading)
    }
    stackView.needsLayout = true
    needsUpdateConstraints = true
  }
  
  /// Finds the center of the given column.
  static func columnCenter(_ index: UInt) -> CGFloat
  {
    return Margins.left + Widths.column * CGFloat(index) + Widths.column / 2
  }
  
  /// Moves the text field out of the way of the lines and refs.
  override func updateConstraints()
  {
    switch displayMode {
      case .refsOnly:
        stackViewInset.constant = 0
      case .titleOnly:
        stackViewInset.constant = Margins.text
      case .graphOnly:
        stackViewInset.constant = 0
      default:
        mutex?.withLock {
          let totalColumns = entry.lines.reduce(entry.dotOffset ?? 0) {
            (oldMax, line) -> UInt in
            max(oldMax, line.parentIndex ?? 0, line.childIndex ?? 0)
          }
          let linesMargin = Margins.left + CGFloat(totalColumns + 1) * Widths.column

          stackViewInset.constant = linesMargin + Margins.text
        }
    }
    super.updateConstraints()
  }
  
  /// Draws the graph lines in the view. Lines extend beyond the cell
  /// bounds by half the intercell spacing so they remain contiguous.
  override func draw(_ dirtyRect: NSRect)
  {
    super.draw(dirtyRect)

    if displayMode.showGraph {
      drawLines()
    }
  }
  
  /// Calculates an offset for graph line corners to avoid awkward breaks
  func cornerOffset(_ offset1: UInt, _ offset2: UInt) -> CGFloat
  {
    let pathOffset = abs(Int(offset1) - Int(offset2))
    let height = Double(pathOffset) * 0.25
    
    return min(CGFloat(height), Widths.line)
  }
  
  var graphOffset: CGFloat = 0

  /// Center X for a graph column, including the row-independent offset.
  func columnCenterX(_ index: UInt) -> CGFloat
  {
    return HistoryCellView.columnCenter(index) + graphOffset
  }

  static func graphContentWidth(maxColumn: UInt) -> CGFloat
  {
    Margins.left + CGFloat(maxColumn + 1) * Widths.column
  }

  func path(for line: HistoryLine) -> NSBezierPath?
  {
    guard let dotOffset = entry.dotOffset
    else { return nil }
    let path = NSBezierPath()

    // Extend lines beyond cell bounds to bridge the intercell gap.
    let overflow: CGFloat = 4
    let top: CGFloat = bounds.size.height + overflow
    let bottom: CGFloat = -overflow

    switch (line.parentIndex, line.childIndex) {

      case (nil, let childIndex?):
        path.move(to: NSPoint(x: columnCenterX(childIndex),
                              y: top))
        path.relativeLine(to: NSPoint(x: 0, y: -cornerOffset(dotOffset,
                                                             childIndex)))
        path.line(to: NSPoint(x: columnCenterX(dotOffset),
                              y: bounds.size.height/2))

      case (let parentIndex?, nil):
        path.move(to: NSPoint(x: columnCenterX(parentIndex),
                              y: bottom))
        path.relativeLine(to: NSPoint(x: 0, y: cornerOffset(dotOffset,
                                                            parentIndex)))
        path.line(to: NSPoint(x: columnCenterX(dotOffset),
                              y: bounds.size.height/2))

      case (let parentIndex?, let childIndex?):
        path.move(to: NSPoint(x: columnCenterX(childIndex),
                              y: top))
        if parentIndex != childIndex {
          let cornerOffset = self.cornerOffset(childIndex, parentIndex)

          path.relativeLine(to: NSPoint(x: 0, y: -cornerOffset))
          path.line(to: NSPoint(x: columnCenterX(parentIndex),
                                y: cornerOffset))
        }
        path.line(to: NSPoint(x: columnCenterX(parentIndex),
                              y: bottom))

      case (nil, nil):
        return nil
    }
    return path
  }
  
  func drawLines()
  {
    let dotValues = mutex.withLock {
      (entry.dotOffset, entry.dotColorIndex)
    }
    guard let dotOffset = dotValues.0,
          let dotColorIndex = dotValues.1
    else { return }
    
    let accentStroke = NSColor.separatorColor.withAlphaComponent(
        LiquidGlassAccessibility.shouldIncreaseContrast ? 0.7 : 0.35)

    for line in entry.lines {
      guard let path = path(for: line)
      else { continue }
      
      let colorIndex = Int(line.colorIndex) %
                       HistoryCellView.lineColors.count
      let lineColor =  HistoryCellView.lineColors[colorIndex]
      
      path.lineJoinStyle = .round
      if line.parentIndex != line.childIndex {
        accentStroke.setStroke()
        path.lineWidth = Widths.line + 1.0
        path.stroke()
      }
      lineColor.setStroke()
      path.lineWidth = Widths.line
      path.stroke()
    }

    let dotSize: CGFloat = 6.0
    let dotPath = NSBezierPath(ovalIn:
            NSRect(x: columnCenterX(dotOffset) - dotSize/2,
                   y: bounds.size.height/2 - dotSize/2,
                   width: dotSize, height: dotSize))
    let colorIndex = Int(dotColorIndex) % HistoryCellView.lineColors.count
    let baseDotColor = HistoryCellView.lineColors[colorIndex]
    let dotColor = baseDotColor.blended(withFraction: 0.5,
                                        of: NSColor.textColor) ?? baseDotColor
    
    accentStroke.setStroke()
    dotPath.lineWidth = 1.0
    dotPath.stroke()
    dotColor.setFill()
    dotPath.fill()
  }
}
