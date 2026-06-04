import Cocoa

@MainActor
protocol HelmTableViewDelegate: AnyObject
{
  /// The user has clicked on the selected row.
  func tableViewClickedSelectedRow(_ tableView: NSTableView)

  /// Finds the menu for a click in the given cell
  func menu(forRow row: Int, column: Int) -> NSMenu?
}

final class HistoryTableView: ContextMenuTableView
{
  private var popover: NSPopover?
  private var popoverTimer: Timer?
  private var hoveredRow: Int = -1

  override func mouseDown(with event: NSEvent)
  {
    let oldSelection = selectedRowIndexes

    super.mouseDown(with: event)

    let newSelection = selectedRowIndexes

    if oldSelection == newSelection,
       let xtDelegate = delegate as? HelmTableViewDelegate {
      xtDelegate.tableViewClickedSelectedRow(self)
    }
  }

  override func updateMenu(forRow row: Int, column: Int)
  {
    menu = (delegate as? HelmTableViewDelegate)?
        .menu(forRow: row, column: column)
  }

  // MARK: - Column sizing

  override func tile()
  {
    sizeColumnsProportionally()
    super.tile()
    (delegate as? HistoryTableController)?.updateGraphColumnOffset()
  }

  /// Resizes the three visible columns to 30% / 10% / 60%.
  private func sizeColumnsProportionally()
  {
    guard let clipView = enclosingScrollView?.contentView
    else { return }

    let visibleColumns = tableColumns.filter { !$0.isHidden }
    let availableWidth = clipView.bounds.width
    let spacing = intercellSpacing.width
    let totalSpacing = spacing * CGFloat(max(0, visibleColumns.count - 1))
    let contentWidth = max(0, availableWidth - totalSpacing)

    let refsWidth = floor(contentWidth * 0.30)
    let graphWidth = floor(contentWidth * 0.10)
    let commitWidth = contentWidth - refsWidth - graphWidth

    for column in visibleColumns {
      switch column.identifier.rawValue {
        case "refs":
          column.width = refsWidth
        case "graph":
          column.width = graphWidth
        case "commit":
          column.width = commitWidth
        default:
          break
      }
    }
  }

  /// Prevents the table view from ever exceeding the clip view width,
  /// which would cause an unwanted horizontal scrollbar.
  override func setFrameSize(_ newSize: NSSize)
  {
    var size = newSize

    if let clipView = superview {
      size.width = min(size.width, clipView.bounds.width)
    }
    super.setFrameSize(size)
  }

  // MARK: - Callout tooltip

  override func updateTrackingAreas()
  {
    super.updateTrackingAreas()

    for area in trackingAreas where area.owner === self {
      removeTrackingArea(area)
    }
    addTrackingArea(NSTrackingArea(
        rect: bounds,
        options: [.mouseMoved, .mouseEnteredAndExited,
                  .activeInKeyWindow],
        owner: self, userInfo: nil))
  }

  override func mouseMoved(with event: NSEvent)
  {
    super.mouseMoved(with: event)

    let point = convert(event.locationInWindow, from: nil)
    let row = self.row(at: point)

    if row != hoveredRow {
      dismissPopover()
      hoveredRow = row
      schedulePopover()
    }
  }

  override func mouseExited(with event: NSEvent)
  {
    super.mouseExited(with: event)
    dismissPopover()
    hoveredRow = -1
  }

  private func schedulePopover()
  {
    popoverTimer?.invalidate()

    guard hoveredRow >= 0
    else { return }

    popoverTimer = Timer.scheduledTimer(
        withTimeInterval: Self.systemTooltipDelay, repeats: false)
    { [weak self] _ in
      MainActor.assumeIsolated {
        self?.showPopover()
      }
    }
  }

  /// Matches AppKit's `toolTip` initial delay. Reads the user default
  /// `NSInitialToolTipDelay` (ms) and falls back to 2 s if unset.
  private static var systemTooltipDelay: TimeInterval
  {
    let ms = UserDefaults.standard.integer(forKey: "NSInitialToolTipDelay")

    return ms > 0 ? TimeInterval(ms) / 1000.0 : 2.0
  }

  private func showPopover()
  {
    guard hoveredRow >= 0,
          let commitColumn = tableColumns.firstIndex(
              where: { $0.identifier.rawValue == "commit" }),
          let cell = view(atColumn: commitColumn, row: hoveredRow,
                          makeIfNecessary: false)
                     as? HistoryCellView,
          let message = cell.popoverMessage
    else { return }

    let maxWidth: CGFloat = 340
    let padding = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

    let label = NSTextField(wrappingLabelWithString: message)

    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .labelColor
    label.isEditable = false
    label.isBordered = false
    label.drawsBackground = false
    label.maximumNumberOfLines = 20
    label.preferredMaxLayoutWidth = maxWidth - padding.left - padding.right

    let textSize = label.fittingSize
    let contentSize = NSSize(
        width: textSize.width + padding.left + padding.right,
        height: textSize.height + padding.top + padding.bottom)

    label.frame = NSRect(x: padding.left, y: padding.bottom,
                         width: textSize.width,
                         height: textSize.height)

    let vc = NSViewController()

    vc.view = NSView(frame: NSRect(origin: .zero, size: contentSize))
    vc.view.addSubview(label)
    vc.preferredContentSize = contentSize

    let pop = NSPopover()

    pop.contentViewController = vc
    pop.behavior = .semitransient
    pop.animates = true

    // Anchor at the end of the commit text
    let anchorRect: NSRect
    if let label = cell.labelField {
      let textWidth = label.attributedStringValue.size().width
      let labelInCell = label.convert(label.bounds, to: self)
      anchorRect = NSRect(x: labelInCell.origin.x + textWidth + 8,
                          y: labelInCell.origin.y,
                          width: 1,
                          height: labelInCell.height)
    }
    else {
      anchorRect = rect(ofRow: hoveredRow)
    }

    pop.show(relativeTo: anchorRect, of: self,
             preferredEdge: .maxX)
    popover = pop
  }

  private func dismissPopover()
  {
    popoverTimer?.invalidate()
    popoverTimer = nil
    popover?.performClose(nil)
    popover = nil
  }
}
