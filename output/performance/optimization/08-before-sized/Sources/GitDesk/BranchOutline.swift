import AppKit

final class BranchCell: NSTableCellView {
  let branchIcon = NSImageView()
  var titleRect: NSRect? {
    guard let textField, let cell = textField.cell else { return nil }
    var rect = convert(cell.drawingRect(forBounds: textField.bounds), from: textField)
    rect.size.width = (textField.stringValue as NSString).size(withAttributes: [.font: textField.font ?? Theme.font]).width
    return rect
  }
}

/// The document grows to fit expanded branches; the clip view remains the hover boundary.
final class BranchOutline: MenuOutline, ThemeUpdating {
  var contentWidthForItem: ((Any) -> CGFloat)?
  private(set) var hoveredRow = -1
  private(set) var expansionView: BranchExpansionView?
  private weak var expansionSource: BranchCell?
  private var sourceToolTip: String?
  private var hoverTrackingArea: NSTrackingArea?
  private var observers: [NSObjectProtocol] = []
  private var fitting = false
  private var updatingHover = false

  func fitContentWidth() {
    guard !fitting, let scroll = enclosingScrollView, let column = outlineTableColumn else { return }
    fitting = true
    defer { fitting = false }
    var width = scroll.contentSize.width
    for row in 0..<numberOfRows {
      guard let item = item(atRow: row) else { continue }
      width = max(width, CGFloat(level(forRow: row) + 1) * indentationPerLevel
        + (contentWidthForItem?(item) ?? 0))
    }
    if abs(column.width - width) > 0.5 { column.width = width }
    if abs(frame.width - width) > 0.5 {
      setFrameSize(NSSize(width: width, height: frame.height))
    }
    let clip = scroll.contentView
    let x = min(clip.bounds.minX, max(0, width - clip.bounds.width))
    if x != clip.bounds.minX {
      clip.scroll(to: NSPoint(x: x, y: clip.bounds.minY))
      scroll.reflectScrolledClipView(clip)
    }
  }
  override func layout() {
    super.layout()
    fitContentWidth()
  }
  override func reloadData() {
    dismissTextExpansion()
    setHoveredRow(-1)
    super.reloadData()
    needsLayout = true
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(rect: .zero,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    hoverTrackingArea = area
    updateHoveredRow()
  }
  override func mouseEntered(with event: NSEvent) { updateHoveredRow(at: event.locationInWindow) }
  override func mouseMoved(with event: NSEvent) { updateHoveredRow(at: event.locationInWindow) }
  override func mouseExited(with event: NSEvent) {
    setHoveredRow(-1)
    dismissTextExpansion()
  }
  override func mouseDown(with event: NSEvent) {
    dismissTextExpansion()
    super.mouseDown(with: event)
  }
  override func keyDown(with event: NSEvent) {
    dismissTextExpansion()
    super.keyDown(with: event)
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    dismissTextExpansion()
    return super.menu(for: event)
  }
  override func scrollWheel(with event: NSEvent) {
    dismissTextExpansion()
    super.scrollWheel(with: event)
    updateHoveredRow(at: event.locationInWindow)
  }
  private func setHoveredRow(_ row: Int) {
    guard row != hoveredRow else { return }
    let previous = hoveredRow
    hoveredRow = row
    for index in [previous, row] where index >= 0 && index < numberOfRows {
      (rowView(atRow: index, makeIfNecessary: false) as? SelectionRow)?.isHovered = index == row
    }
  }
  private func updateHoveredRow(at location: NSPoint? = nil) {
    guard !updatingHover else { return }
    updatingHover = true
    defer { updatingHover = false }
    guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else {
      setHoveredRow(-1)
      dismissTextExpansion()
      return
    }
    let point = convert(location ?? window.mouseLocationOutsideOfEventStream, from: nil)
    setHoveredRow(visibleRect.contains(point) ? row(at: point) : -1)
    guard hoveredRow >= 0, let content = window.contentView,
      let cell = view(atColumn: 0, row: hoveredRow, makeIfNecessary: false) as? BranchCell,
      let field = cell.textField else {
      dismissTextExpansion()
      return
    }
    cell.layoutSubtreeIfNeeded()
    guard let titleRect = cell.titleRect else { dismissTextExpansion(); return }
    // A wide document never truncates its label, but the scroll viewport can clip it.
    let title = convert(titleRect, from: cell)
    guard title.minX < visibleRect.minX || title.maxX > visibleRect.maxX else {
      dismissTextExpansion()
      return
    }
    if expansionSource === cell { return }
    let available = content.convert(window.contentLayoutRect, from: nil)
      .intersection(content.bounds).insetBy(dx: 2, dy: 2)
    let anchor = content.convert(title, from: self)
    guard let layout = LogTextExpansionLayout.make(text: field.stringValue,
      font: field.font ?? Theme.font, sourceRect: anchor, containerBounds: available,
      flipped: content.isFlipped) else { dismissTextExpansion(); return }
    dismissTextExpansion()
    let rowRect = content.convert(rect(ofRow: hoveredRow).intersection(visibleRect), from: self)
    let fill = selectedRowIndexes.contains(hoveredRow) && window.isKeyWindow && window.firstResponder === self
      ? Theme.activeSelection : Theme.inactiveSelection
    let expanded = BranchExpansionView(layout: layout, rowRect: rowRect,
      textColor: field.textColor ?? Theme.text, fillColor: fill)
    expansionSource = cell
    sourceToolTip = cell.toolTip
    cell.toolTip = nil
    expansionView = expanded
    content.addSubview(expanded, positioned: .above, relativeTo: nil)
    if cell.branchIcon.image != nil {
      let iconRect = expanded.convert(cell.branchIcon.bounds, from: cell.branchIcon)
      guard iconRect.maxX <= expanded.textOrigin.x else { return }
      let image = NSImageView(frame: iconRect)
      image.image = cell.branchIcon.image
      image.contentTintColor = cell.branchIcon.contentTintColor
      expanded.addSubview(image)
    }
  }
  func dismissTextExpansion() {
    expansionSource?.toolTip = sourceToolTip
    sourceToolTip = nil
    expansionSource = nil
    expansionView?.removeFromSuperview()
    expansionView = nil
  }
  func refreshTheme() {
    dismissTextExpansion()
    needsDisplay = true
  }
  override func viewDidHide() {
    super.viewDidHide()
    dismissTextExpansion()
    setHoveredRow(-1)
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    dismissTextExpansion()
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers = []
    guard let window else { return }
    window.acceptsMouseMovedEvents = true
    func observe(_ name: Notification.Name, object: AnyObject, action: @escaping (BranchOutline) -> Void) {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: object,
        queue: .main) { [weak self] _ in if let self { action(self) } })
    }
    for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification,
      NSWindow.willMiniaturizeNotification, NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
      observe(name, object: window) {
        $0.dismissTextExpansion()
        $0.setHoveredRow(-1)
        $0.needsLayout = true
      }
    }
    for name in [NSOutlineView.itemDidExpandNotification, NSOutlineView.itemDidCollapseNotification] {
      observe(name, object: self) {
        $0.dismissTextExpansion()
        $0.setHoveredRow(-1)
        $0.needsLayout = true
      }
    }
    if let clip = enclosingScrollView?.contentView {
      clip.postsBoundsChangedNotifications = true
      observe(NSView.boundsDidChangeNotification, object: clip) {
        $0.dismissTextExpansion()
        $0.needsLayout = true
        $0.updateHoveredRow()
      }
    }
    needsLayout = true
  }
  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    expansionView?.removeFromSuperview()
  }
}

/// Draw the expanded name over neighboring panes, retaining the original row's icon and fill.
final class BranchExpansionView: NSView {
  let textLayout: LogTextExpansionLayout
  let textColor: NSColor
  let fillColor: NSColor
  let textOrigin: NSPoint
  override var isFlipped: Bool { true }
  init(layout: LogTextExpansionLayout, rowRect: NSRect, textColor: NSColor, fillColor: NSColor) {
    textLayout = layout
    self.textColor = textColor
    self.fillColor = fillColor
    let left = min(rowRect.minX + 4, layout.frame.minX)
    let right = max(rowRect.maxX - 4, layout.frame.maxX)
    textOrigin = NSPoint(x: layout.frame.minX - left + LogTextExpansionLayout.padding.width,
      y: LogTextExpansionLayout.padding.height)
    super.init(frame: NSRect(x: left, y: layout.frame.minY, width: right - left, height: layout.frame.height))
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel(layout.lines.joined(separator: "\n"))
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
    fillColor.setFill()
    shape.fill()
    Theme.line.setStroke()
    shape.stroke()
    for (index, line) in textLayout.lines.enumerated() {
      (line as NSString).draw(at: NSPoint(x: textOrigin.x,
        y: textOrigin.y + CGFloat(index) * textLayout.lineHeight),
        withAttributes: [.font: textLayout.font, .foregroundColor: textColor])
    }
  }
}
