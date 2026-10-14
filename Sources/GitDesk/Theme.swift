import AppKit
import GitDeskCore

enum Theme {
  static var current = AppTheme.saved()
  static let background = dynamic(.background)
  static let chrome = dynamic(.chrome)
  static let line = dynamic(.line)
  static let border = dynamic(.border)
  static let text = dynamic(.text)
  static let muted = dynamic(.muted)
  static let selection = dynamic(.selection)
  static let currentBranchBackground = dynamic(.currentBranchBackground)
  static let activeSelection = dynamic(.activeSelection)
  static let inactiveSelection = dynamic(.inactiveSelection)
  static let hover = dynamic(.hover)
  static let blue = dynamic(.blue)
  static let green = dynamic(.green)
  static let red = dynamic(.red)
  static let yellow = dynamic(.yellow)
  static let accent = dynamic(.accent)
  static let pressedAccent = dynamic(.pressedAccent)
  static let diffRemoved = dynamic(.diffRemoved)
  static let diffAdded = dynamic(.diffAdded)
  static let diffModified = dynamic(.diffModified)
  static let diffGap = dynamic(.diffGap)
  static let keyword = dynamic(.keyword)
  static let string = dynamic(.string)
  static let heading = dynamic(.heading)
  static let graph: [NSColor] = [
    (0x9F3C54, 0xA33D55), (0xA6753D, 0x95652F), (0x489C38, 0x39832D),
    (0x7E47A6, 0x7B43A1), (0x4149A7, 0x4149A7), (0x2D9B85, 0x268773),
  ].enumerated().map { index, pair in
    NSColor(name: NSColor.Name("GitDesk.graph.\(index)")) { _ in
      NSColor(hex: current.isDark ? pair.0 : pair.1)
    }
  }
  static let font = NSFont.systemFont(ofSize: 13)
  static var branchIcon: NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
    text.setStroke()
    let path = NSBezierPath()
    path.lineWidth = 1.1
    path.move(to: NSPoint(x: 4, y: 1))
    path.line(to: NSPoint(x: 4, y: 11))
    path.move(to: NSPoint(x: 4, y: 5))
    path.curve(to: NSPoint(x: 12, y: 10), controlPoint1: NSPoint(x: 12, y: 5), controlPoint2: NSPoint(x: 12, y: 5))
    path.stroke()
    for point in [NSPoint(x: 4, y: 13), NSPoint(x: 12, y: 12)] {
      NSBezierPath(ovalIn: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)).stroke()
    }
    return true
    }
    image.isTemplate = true
    return image
  }
}
extension NSColor {
  convenience init(hex: UInt32) {
    self.init(
      srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
      blue: CGFloat(hex & 255) / 255, alpha: 1)
  }
}
protocol ThemeUpdating { func refreshTheme() }

final class Surface: NSView, ThemeUpdating {
  var fillColor: NSColor { didSet { refreshTheme() } }
  var borderColor: NSColor? { didSet { refreshTheme() } }
  var islandPanel = false { didSet { refreshTheme() } }
  init(_ color: NSColor = Theme.background, islandPanel: Bool = false) {
    fillColor = color
    self.islandPanel = islandPanel
    super.init(frame: .zero)
    wantsLayer = true
    refreshTheme()
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshTheme()
  }
  func refreshTheme() {
    layer?.backgroundColor = fillColor.cgColor
    if let borderColor { layer?.borderColor = borderColor.cgColor }
    if islandPanel {
      layer?.cornerRadius = Theme.current.isIsland ? 10 : 0
      layer?.masksToBounds = true
    }
  }
}
final class GitSplitView: NSSplitView {
  override var dividerColor: NSColor { Theme.line }
}
final class RepositoryHeader: NSView {
  var projectColor = Theme.chrome { didSet { needsDisplay = true } }
  override var mouseDownCanMoveWindow: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    let tint = Theme.chrome.blended(withFraction: 0.24, of: projectColor) ?? Theme.chrome
    NSGradient(colors: [Theme.chrome, tint, Theme.chrome])?
      .draw(in: bounds, angle: 0)
  }
}

final class RepositoryTitlebarAccessoryView: NSView {
  private let controls: NSStackView
  init(controls: NSStackView, width: CGFloat) {
    self.controls = controls
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: 42))
    controls.translatesAutoresizingMaskIntoConstraints = true
    addSubview(controls)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    guard let button = window?.standardWindowButton(.closeButton) else { return }
    // The compact toolbar's accessory bounds do not share the window's top inset.
    // Convert the actual traffic-light center so resize and backing scale stay aligned.
    let center = convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button).y
    controls.frame = NSRect(x: 0, y: center - 16, width: max(0, bounds.width - 14), height: 32)
  }
}

enum ProjectIdentity {
  static func initials(_ name: String) -> String {
    let separated = name.replacingOccurrences(
      of: "([\\p{Ll}\\d])(\\p{Lu})", with: "$1 $2", options: .regularExpression)
    let words = separated.components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    let initials = words.prefix(2).compactMap(\.first).map(String.init).joined()
    return initials.isEmpty ? "?" : initials.uppercased()
  }
  static func color(for url: URL) -> NSColor {
    let palette: [UInt32] = [
      0x689F70, 0x569EAD, 0x6B8BC5, 0x9473BD, 0xBD738B, 0xB58A58,
      0x629C93, 0x8D9663, 0xB47869,
    ]
    let hash = url.standardizedFileURL.resolvingSymlinksInPath().path.utf8.reduce(
      UInt64(14_695_981_039_346_656_037)
    ) {
      ($0 ^ UInt64($1)) &* 1_099_511_628_211
    }
    return NSColor(hex: palette[Int(hash % UInt64(palette.count))])
  }
  static func drawBadge(name: String, color: NSColor, in rect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
    NSGradient(starting: color, ending: color.blended(withFraction: 0.12, of: .white) ?? color)?
      .draw(in: rect, angle: 60)
    let text = initials(name) as NSString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
      .foregroundColor: NSColor.white,
    ]
    let size = text.size(withAttributes: attributes)
    text.draw(
      at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
      withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
  }
  static func image(for url: URL) -> NSImage {
    NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
      drawBadge(name: url.lastPathComponent, color: color(for: url), in: rect)
      return true
    }
  }
}

final class HeaderMenuButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  enum Kind { case repository, branch }
  let kind: Kind
  var handler: (() -> Void)?
  var projectColor = Theme.green { didSet { needsDisplay = true } }
  override var title: String {
    didSet {
      invalidateIntrinsicContentSize()
      needsDisplay = true
      setAccessibilityLabel(title)
    }
  }
  init(_ title: String, kind: Kind) {
    self.kind = kind
    super.init(frame: .zero)
    self.title = title
    isBordered = false
    target = self
    action = #selector(invoke)
    font = .systemFont(ofSize: 13, weight: .regular)
    translatesAutoresizingMaskIntoConstraints = false
    setAccessibilityLabel(title)
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
  }
  required init?(coder: NSCoder) { fatalError() }
  private var titleInset: CGFloat { kind == .repository ? 26 : 20 }
  override var intrinsicContentSize: NSSize {
    let width = (title as NSString).size(withAttributes: [.font: font!]).width
    return NSSize(width: min(width, kind == .repository ? 220 : 280) + titleInset + 16, height: 32)
  }
  override func draw(_ dirtyRect: NSRect) {
    let scale = window?.backingScaleFactor ?? 1
    let center = (bounds.midY * scale).rounded() / scale
    if isHighlighted {
      Theme.hover.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
    if kind == .repository {
      ProjectIdentity.drawBadge(
        name: title, color: projectColor,
        in: NSRect(x: 0, y: center - 10, width: 20, height: 20))
    } else {
      Theme.branchIcon.draw(in: NSRect(x: 0, y: center - 7, width: 14, height: 14),
        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let height = (title as NSString).size(withAttributes: [.font: font!]).height
    (title as NSString).draw(
      in: NSRect(x: titleInset, y: ((center - height / 2) * scale).rounded() / scale,
        width: max(0, bounds.width - titleInset - 16), height: height),
      withAttributes: [.font: font!, .foregroundColor: Theme.text, .paragraphStyle: paragraph])
    Theme.text.withAlphaComponent(0.85).setStroke()
    let chevron = NSBezierPath()
    chevron.lineWidth = 1
    chevron.move(to: NSPoint(x: bounds.width - 10, y: center - 2))
    chevron.line(to: NSPoint(x: bounds.width - 6, y: center + 2))
    chevron.line(to: NSPoint(x: bounds.width - 2, y: center - 2))
    chevron.stroke()
  }
  @objc private func invoke() { handler?() }
}

func label(_ text: String, color: NSColor = Theme.text, size: CGFloat = 13, bold: Bool = false)
  -> NSTextField
{
  let field = NSTextField(labelWithString: text)
  field.textColor = color
  field.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
  field.lineBreakMode = .byTruncatingTail
  return field
}
final class ActionButton: NSButton {
  enum CommitStyle { case primary, secondary }
  var commitStyle: CommitStyle? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
  var handler: (() -> Void)?
  var isTab = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
  override var intrinsicContentSize: NSSize {
    if commitStyle != nil { return NSSize(width: (title as NSString).size(withAttributes: [.font: Theme.font]).width + 28, height: 28) }
    if isTab { return NSSize(width: (title as NSString).size(withAttributes: [.font: Theme.font]).width + 14, height: 30) }
    return super.intrinsicContentSize
  }
  override func draw(_ dirtyRect: NSRect) {
    if let commitStyle {
      let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
      (commitStyle == .primary ? (isHighlighted ? Theme.pressedAccent : Theme.accent) : Theme.background).setFill()
      path.fill()
      if commitStyle == .secondary { Theme.border.setStroke(); path.lineWidth = 1; path.stroke() }
      let size = (title as NSString).size(withAttributes: [.font: Theme.font])
      (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
        withAttributes: [.font: Theme.font, .foregroundColor: commitStyle == .primary ? NSColor.white : Theme.text])
      return
    }
    guard isTab else { super.draw(dirtyRect); return }
    if isBordered {
      let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1.5), xRadius: 4, yRadius: 4)
      Theme.chrome.setFill()
      path.fill()
      Theme.border.setStroke()
      path.lineWidth = 1
      path.stroke()
    }
    let size = (title as NSString).size(withAttributes: [.font: Theme.font])
    (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
      withAttributes: [.font: Theme.font, .foregroundColor: Theme.text])
  }
  init(
    _ title: String = "", symbol: String? = nil, tooltip: String? = nil,
    size: CGFloat = 30,
    action: @escaping () -> Void
  ) {
    super.init(frame: .zero)
    self.title = title
    self.handler = action
    target = self
    self.action = #selector(invoke)
    isBordered = false
    bezelStyle = .recessed
    font = Theme.font
    contentTintColor = Theme.text
    if let symbol {
      image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip ?? title)
      imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    }
    toolTip = tooltip ?? title
    setAccessibilityLabel(tooltip ?? title)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: size).isActive = true
    if title.isEmpty { widthAnchor.constraint(equalToConstant: size).isActive = true }
  }
  @objc func invoke() { handler?() }
  required init?(coder: NSCoder) { fatalError() }
}
func row(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
  let stack = NSStackView(views: views)
  stack.orientation = .horizontal
  stack.alignment = .centerY
  stack.spacing = spacing
  return stack
}
func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
  child.translatesAutoresizingMaskIntoConstraints = false
  parent.addSubview(child)
  NSLayoutConstraint.activate([
    child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
    child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
    child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
    child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
  ])
}
func makePanel(_ toolbar: NSView, body: NSView, height: CGFloat = 42) -> NSView {
  let view = Surface()
  toolbar.translatesAutoresizingMaskIntoConstraints = false
  body.translatesAutoresizingMaskIntoConstraints = false
  view.addSubview(toolbar)
  view.addSubview(body)
  NSLayoutConstraint.activate([
    toolbar.topAnchor.constraint(equalTo: view.topAnchor),
    toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
    toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
    toolbar.heightAnchor.constraint(equalToConstant: height),
    body.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 1),
    body.leadingAnchor.constraint(equalTo: view.leadingAnchor),
    body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    body.bottomAnchor.constraint(equalTo: view.bottomAnchor),
  ])
  return view
}
private final class TextScrollView: NSScrollView {
  override func tile() {
    super.tile()
    guard let text = documentView as? NSTextView else { return }
    let viewport = contentSize
    text.minSize = NSSize(width: 0, height: viewport.height)
    let size = NSSize(width: viewport.width, height: max(viewport.height, text.frame.height))
    if text.frame.size != size { text.setFrameSize(size) }
  }
}

func scrollView(_ document: NSView) -> NSScrollView {
  let scroll: NSScrollView
  if let text = document as? NSTextView {
    scroll = TextScrollView()
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    text.autoresizingMask = [.width]
    text.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    text.textContainer?.widthTracksTextView = true
  } else {
    scroll = NSScrollView()
  }
  scroll.documentView = document
  scroll.hasVerticalScroller = true
  scroll.hasHorizontalScroller = true
  scroll.autohidesScrollers = true
  scroll.drawsBackground = true
  scroll.backgroundColor = Theme.background
  return scroll
}
func configureTable(_ table: NSTableView) {
  table.style = .plain
  table.rowSizeStyle = .custom
  table.backgroundColor = Theme.background
  table.rowHeight = 27
  table.intercellSpacing = NSSize(width: 0, height: 0)
  table.selectionHighlightStyle = .regular
  table.focusRingType = .none
  table.usesAlternatingRowBackgroundColors = false
  table.headerView = nil
  table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
}
class MenuTable: NSTableView {
  var menuProvider: (() -> NSMenu)?
  func reloadKeepingSelection() {
    let selection = selectedRowIndexes
    reloadData()
    selectRowIndexes(selection, byExtendingSelection: false)
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let row = row(at: convert(event.locationInWindow, from: nil))
    if row >= 0 && !selectedRowIndexes.contains(row) {
      selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    return menuProvider?()
  }
}
/// Keep the message column flexible while reserving only the space metadata needs.
final class LogTable: MenuTable {
  var onNearBottom: (() -> Void)?
  func requestMoreIfNeeded() {
    guard window != nil, !isHiddenOrHasHiddenAncestor, numberOfRows > 0,
      visibleRect.height > 0 else { return }
    let visible = rows(in: visibleRect)
    if visible.location != NSNotFound, visible.length > 0,
      visible.location + visible.length >= numberOfRows - 10 {
      onNearBottom?()
    }
  }
  var graphWidth: CGFloat = 44
  var authorWidth: CGFloat = 90
  private(set) var hoveredRow = -1
  private var fitting = false
  private struct ColumnDrag {
    let column: Int
    let startX: CGFloat
    let widths: [CGFloat]
  }
  private var columnDrag: ColumnDrag?
  private var resizedAuthorWidth: CGFloat?
  private var resizedDateWidth: CGFloat?
  private var scrollObserver: NSObjectProtocol?
  private var hoverTrackingArea: NSTrackingArea?
  private var windowObservers: [NSObjectProtocol] = []
  private var expansionView: LogTextExpansionView?
  private weak var expansionSource: NSView?
  private var expansionAnchor = NSRect.zero
  private var expansionBounds = NSRect.zero
  private var expansionToolTip: String?
  private func resizeBoundary(at point: NSPoint) -> Int? {
    guard tableColumns.count == 4, visibleRect.contains(point) else { return nil }
    let visible = tableColumns.indices.filter { !tableColumns[$0].isHidden }
    return visible.dropLast().first { $0 != 0 && abs(point.x - rect(ofColumn: $0).maxX) <= 4 }
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    if resizeBoundary(at: convert(point, from: superview)) != nil { return self }
    return super.hitTest(point)
  }
  override func resetCursorRects() {
    super.resetCursorRects()
    guard tableColumns.count == 4 else { return }
    let visible = tableColumns.indices.filter { !tableColumns[$0].isHidden }
    for column in visible.dropLast() where column != 0 {
      let strip = NSRect(x: rect(ofColumn: column).maxX - 4, y: visibleRect.minY,
        width: 8, height: visibleRect.height).intersection(visibleRect)
      if !strip.isEmpty { addCursorRect(strip, cursor: .resizeLeftRight) }
    }
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
    if let column = resizeBoundary(at: convert(event.locationInWindow, from: nil)) {
      columnDrag = ColumnDrag(column: column, startX: event.locationInWindow.x,
        widths: tableColumns.map(\.width))
      NSCursor.resizeLeftRight.set()
      return
    }
    super.mouseDown(with: event)
  }
  override func mouseDragged(with event: NSEvent) {
    guard let drag = columnDrag else { super.mouseDragged(with: event); return }
    guard let next = tableColumns.indices.first(where: { $0 > drag.column && !tableColumns[$0].isHidden }) else { return }
    let left = tableColumns[drag.column], right = tableColumns[next]
    let leftWidth = drag.widths[drag.column], rightWidth = drag.widths[next]
    let minimum = max(left.minWidth - leftWidth, rightWidth - right.maxWidth)
    let maximum = min(left.maxWidth - leftWidth, rightWidth - right.minWidth)
    let delta = min(max(event.locationInWindow.x - drag.startX, minimum), maximum)
    guard abs(delta) > 0.5 || left.width != leftWidth else { return }
    left.width = leftWidth + delta
    right.width = rightWidth - delta
    resizedAuthorWidth = tableColumns[2].width
    resizedDateWidth = tableColumns[3].width
    window?.invalidateCursorRects(for: self)
    NSCursor.resizeLeftRight.set()
  }
  override func mouseUp(with event: NSEvent) {
    guard columnDrag != nil else { super.mouseUp(with: event); return }
    columnDrag = nil
    fitColumns()
    window?.invalidateCursorRects(for: self)
    updateHoveredRow(at: event.locationInWindow)
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
    requestMoreIfNeeded()
  }
  private func updateHoveredRow(at location: NSPoint? = nil) {
    guard columnDrag == nil else { return }
    guard let window, !isHiddenOrHasHiddenAncestor else {
      setHoveredRow(-1)
      dismissTextExpansion()
      return
    }
    let point = convert(location ?? window.mouseLocationOutsideOfEventStream, from: nil)
    setHoveredRow(visibleRect.contains(point) ? row(at: point) : -1)
    if resizeBoundary(at: point) != nil { dismissTextExpansion() }
    else { updateTextExpansion(at: point) }
  }
  private func updateTextExpansion(at point: NSPoint) {
    let column = column(at: point)
    guard hoveredRow >= 0, column >= 0, let window, window.isVisible,
      let content = window.contentView,
      let cell = view(atColumn: column, row: hoveredRow, makeIfNecessary: false),
      let text = (cell as? LogExpandableCell)?.hoverText,
      (cell is LogMetadataCell ? cell.bounds : text.rect)
        .contains(cell.convert(point, from: self)) else {
      dismissTextExpansion()
      return
    }
    let anchor = content.convert(text.rect, from: cell)
    let available = content.convert(window.contentLayoutRect, from: nil)
      .intersection(content.bounds).insetBy(dx: 2, dy: 2)
    if expansionSource === cell && expansionAnchor == anchor && expansionBounds == available { return }
    guard text.isTruncated,
      let layout = LogTextExpansionLayout.make(text: text.text, font: text.font,
        sourceRect: anchor, containerBounds: available, flipped: content.isFlipped) else {
      dismissTextExpansion()
      return
    }
    dismissTextExpansion()
    let expanded = LogTextExpansionView(layout: layout, textColor: text.color,
      fillColor: Theme.chrome, borderColor: Theme.line)
    expansionView = expanded
    expansionSource = cell
    expansionAnchor = anchor
    expansionBounds = available
    expansionToolTip = cell.toolTip
    cell.toolTip = nil
    content.addSubview(expanded, positioned: .above, relativeTo: nil)
  }
  func dismissTextExpansion() {
    expansionSource?.toolTip = expansionToolTip
    expansionToolTip = nil
    expansionView?.removeFromSuperview()
    expansionView = nil
    expansionSource = nil
  }
  private func setHoveredRow(_ row: Int) {
    guard row != hoveredRow else { return }
    let previous = hoveredRow
    hoveredRow = row
    for index in [previous, row] where index >= 0 && index < numberOfRows {
      // Only invalidate the old and new rows; mouse movement never reloads the log.
      (rowView(atRow: index, makeIfNecessary: false) as? SelectionRow)?.isHovered = index == row
    }
  }
  override func reloadData() {
    columnDrag = nil
    dismissTextExpansion()
    setHoveredRow(-1)
    super.reloadData()
    updateHoveredRow()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    dismissTextExpansion()
    window?.acceptsMouseMovedEvents = true
    windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
    windowObservers = []
    if let window {
      for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification,
        NSWindow.willMiniaturizeNotification, NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
        windowObservers.append(NotificationCenter.default.addObserver(
          forName: name, object: window, queue: .main
        ) { [weak self] _ in
          self?.columnDrag = nil
          self?.dismissTextExpansion()
          if let self { self.window?.invalidateCursorRects(for: self) }
        })
      }
    }
    if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    scrollObserver = nil
    if window != nil, let clip = enclosingScrollView?.contentView {
      clip.postsBoundsChangedNotifications = true
      var lastViewport = clip.bounds
      scrollObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
      ) { [weak self, weak clip] _ in
        guard let clip else { return }
        if clip.bounds.minX != lastViewport.minX || clip.bounds.width != lastViewport.width {
          self?.invalidateViewportRows()
        }
        lastViewport = clip.bounds
        self?.dismissTextExpansion()
        self?.fitColumns()
        self?.updateHoveredRow()
        self?.requestMoreIfNeeded()
      }
    }
    updateHoveredRow()
  }
  deinit {
    if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
    expansionView?.removeFromSuperview()
  }
  func fitColumns() {
    guard !fitting, columnDrag == nil, tableColumns.count == 4,
      let width = enclosingScrollView?.contentSize.width, width > 0 else { return }
    fitting = true
    let requiredGraphWidth = graphWidth
    let author = tableColumns[2].isHidden ? 0 : resizedAuthorWidth ?? authorWidth
    let date = tableColumns[3].isHidden ? 0 : resizedDateWidth ?? 126
    let widths = [requiredGraphWidth, max(tableColumns[1].minWidth,
      width - requiredGraphWidth - author - date), author, date]
    var changed = false
    for (column, value) in zip(tableColumns, widths) where !column.isHidden && abs(column.width - value) > 0.5 {
      column.width = value
      changed = true
    }
    fitting = false
    if changed { window?.invalidateCursorRects(for: self) }
  }
  override func layout() {
    super.layout()
    fitColumns()
    updateHoveredRow()
  }
}

private final class FlatSearchCell: NSSearchFieldCell {
  override func select(withFrame rect: NSRect, in view: NSView, editor: NSText,
    delegate: Any?, start: Int, length: Int) {
    super.select(withFrame: searchTextRect(forBounds: rect), in: view, editor: editor,
      delegate: delegate, start: start, length: length)
  }
  override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText,
    delegate: Any?, event: NSEvent?) {
    super.edit(withFrame: searchTextRect(forBounds: rect), in: view, editor: editor,
      delegate: delegate, event: event)
  }
  override func searchTextRect(forBounds rect: NSRect) -> NSRect {
    NSRect(x: rect.minX + 28, y: rect.midY - 9,
      width: max(0, rect.width - 32 - (stringValue.isEmpty ? 0 : 20)), height: 18)
  }
  override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
    NSRect(x: rect.minX + 7, y: rect.midY - 8, width: 16, height: 16)
  }
  override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
    NSRect(x: rect.maxX - 21, y: rect.midY - 7, width: 14, height: 14)
  }
}
final class FlatSearchField: NSSearchField {
  var showsOutline = true
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    cell = FlatSearchCell(textCell: "")
    isEditable = true
    isSelectable = true
    usesSingleLineMode = true
    isBezeled = false
    isBordered = false
    drawsBackground = false
    font = Theme.font
    textColor = Theme.text
    focusRingType = .none
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: 30).isActive = true
  }
  required init?(coder: NSCoder) { fatalError() }
  override func draw(_ dirtyRect: NSRect) {
    if showsOutline {
      Theme.line.setStroke()
      let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
      border.lineWidth = 1
      border.stroke()
    }
    super.draw(dirtyRect)
  }
}

final class FilterPopup: NSPopUpButton {
  override var intrinsicContentSize: NSSize {
    NSSize(width: min(130, (title as NSString).size(withAttributes: [.font: Theme.font]).width) + 24, height: 30)
  }
  override func draw(_ dirtyRect: NSRect) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let size = (title as NSString).size(withAttributes: [.font: Theme.font])
    (title as NSString).draw(in: NSRect(x: 5, y: bounds.midY - size.height / 2, width: bounds.width - 24, height: size.height), withAttributes: [.font: Theme.font, .foregroundColor: Theme.muted, .paragraphStyle: paragraph])
    Theme.text.setStroke()
    let path = NSBezierPath()
    path.lineWidth = 1
    path.move(to: NSPoint(x: bounds.maxX - 14, y: bounds.midY - 2))
    path.line(to: NSPoint(x: bounds.maxX - 10, y: bounds.midY + 2))
    path.line(to: NSPoint(x: bounds.maxX - 6, y: bounds.midY - 2))
    path.stroke()
  }
}
class MenuOutline: NSOutlineView {
  var menuProvider: (() -> NSMenu)?
  var toggleGrouping: ((Bool) -> Void)?
  var previewSelection: (() -> Void)?
  override func keyDown(with event: NSEvent) {
    if let previewSelection, event.charactersIgnoringModifiers == " ",
      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
      if !event.isARepeat { previewSelection() }
      return
    }
    if let toggleGrouping,
      event.modifierFlags.intersection([.command, .control, .option, .shift]) == .control,
      event.charactersIgnoringModifiers == "p" || event.charactersIgnoringModifiers == "m" {
      toggleGrouping(event.charactersIgnoringModifiers == "p")
      return
    }
    super.keyDown(with: event)
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let row = row(at: convert(event.locationInWindow, from: nil))
    if row >= 0 && !selectedRowIndexes.contains(row) {
      selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    return menuProvider?()
  }
}
extension NSTableView {
  /// Viewport-anchored rounded backgrounds cannot reuse horizontally shifted
  /// backing pixels: AppKit otherwise leaves copies of the old right edge.
  func invalidateViewportRows() {
    setNeedsDisplay(visibleRect)
    let visible = rows(in: visibleRect)
    guard visible.location != NSNotFound, visible.length > 0 else { return }
    for index in visible.location..<min(numberOfRows, visible.location + visible.length) {
      rowView(atRow: index, makeIfNecessary: false)?.needsDisplay = true
    }
  }
}
final class SelectionRow: NSTableRowView {
  var usesInactiveColor = true
  var cornerRadius: CGFloat = 4
  var backgroundTint: NSColor?
  var hoverColor = Theme.hover
  var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
  override var isPreviousRowSelected: Bool { didSet { needsDisplay = true } }
  override var isNextRowSelected: Bool { didSet { needsDisplay = true } }
  private var viewportRowRect: NSRect {
    NSRect(x: visibleRect.minX + 4, y: bounds.minY,
      width: max(0, visibleRect.width - 8), height: bounds.height)
  }
  private var hoverShape: NSBezierPath {
    NSBezierPath(roundedRect: viewportRowRect, xRadius: 4, yRadius: 4)
  }
  override func drawBackground(in dirtyRect: NSRect) {
    // Rounded selection covers only part of a row. Keep the unselected branch
    // tint underneath its outside corners and clear every invalidated pixel.
    (backgroundTint ?? backgroundColor).setFill()
    bounds.fill()
    if isHovered && !isSelected {
      hoverColor.setFill()
      hoverShape.fill()
    }
  }
  override func drawSelection(in dirtyRect: NSRect) {
    (isEmphasized || !usesInactiveColor ? Theme.activeSelection : Theme.inactiveSelection).setFill()
    selectionShape.fill()
  }
  // Like IDEA DefaultTreeUI, join adjacent rows and round only the outside corners.
  // AppKit updates neighbor flags even for rows entering the viewport during scrolling.
  var selectionShape: NSBezierPath {
    let rect = viewportRowRect
    let radius = min(cornerRadius, rect.height / 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    if isPreviousRowSelected {
      shape.appendRect(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: radius))
    }
    if isNextRowSelected {
      shape.appendRect(NSRect(x: rect.minX, y: rect.maxY - radius, width: rect.width, height: radius))
    }
    return shape
  }
}
final class MenuAction: NSObject {
  let handler: () -> Void
  init(_ handler: @escaping () -> Void) { self.handler = handler }
  @objc func invoke() { handler() }
}
func menuItem(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) -> NSMenuItem {
  let action = MenuAction(handler)
  let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
  item.target = action
  item.representedObject = action
  item.isEnabled = enabled
  return item
}
final class GraphCell: NSView {
  static let laneSpacing: CGFloat = 18
  static let leftInset: CGFloat = 16
  static func requiredWidth(lanes: Int) -> CGFloat {
    leftInset + CGFloat(max(0, lanes - 1)) * laneSpacing + 12
  }
  var graph: GraphRow? { didSet { needsDisplay = true } }
  var isHead = false
  override func draw(_ dirtyRect: NSRect) {
    guard let graph else { return }
    NSGraphicsContext.saveGraphicsState()
    bounds.clip()
    Self.draw(graph, isHead: isHead, height: bounds.height)
    NSGraphicsContext.restoreGraphicsState()
  }
  static func draw(_ graph: GraphRow, isHead: Bool, height h: CGFloat, offsetX: CGFloat = 0) {
    let middle = h / 2
    func x(_ lane: Double) -> CGFloat { offsetX + leftInset + CGFloat(lane) * laneSpacing }
    for segment in graph.segments {
      let path = NSBezierPath()
      path.lineWidth = 1.6
      path.move(to: NSPoint(x: x(segment.fromLane), y: h * segment.fromY))
      path.line(to: NSPoint(x: x(segment.toLane), y: h * segment.toY))
      let color = Theme.graph[segment.color % Theme.graph.count]
      color.setStroke()
      path.stroke()
    }
    for arrow in graph.arrows {
      let center = NSPoint(x: x(Double(arrow.lane)), y: middle)
      let direction: CGFloat = arrow.pointsDown ? -1 : 1
      let tip = NSPoint(x: center.x, y: middle + direction * min(9, h * 0.36))
      let path = NSBezierPath()
      path.lineWidth = 1.6
      path.lineJoinStyle = .round
      path.move(to: center)
      path.line(to: tip)
      path.move(to: NSPoint(x: tip.x - 4, y: tip.y - direction * 6))
      path.line(to: tip)
      path.line(to: NSPoint(x: tip.x + 4, y: tip.y - direction * 6))
      Theme.graph[arrow.color % Theme.graph.count].setStroke()
      path.stroke()
    }
    let color = Theme.graph[graph.color % Theme.graph.count]
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: x(Double(graph.lane)) - 4, y: middle - 4, width: 8, height: 8)).fill()
    if isHead {
      color.setStroke()
      let ring = NSBezierPath(
        ovalIn: NSRect(x: x(Double(graph.lane)) - 6, y: middle - 6, width: 12, height: 12))
      ring.lineWidth = 1.5
      ring.stroke()
    }
  }
}

final class PlaceholderTextView: NSTextView {
  var placeholder = "Commit Message"
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    if string.isEmpty {
      (placeholder as NSString).draw(
        at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
        withAttributes: [.font: font ?? Theme.font, .foregroundColor: Theme.muted])
    }
  }
  override func didChangeText() {
    super.didChangeText()
    needsDisplay = true
  }
}
func styleCheckbox(_ button: NSButton) {
  button.attributedTitle = NSAttributedString(
    string: button.title,
    attributes: [.foregroundColor: Theme.text, .font: button.font ?? Theme.font])
}

func labeledCheckbox(_ button: NSButton, title: String) -> NSStackView {
  button.title = ""
  button.setAccessibilityLabel(title)
  let caption = ActionButton(title) { [weak button] in button?.performClick(nil) }
  caption.font = button.font ?? Theme.font
  return row([button, caption], spacing: 2)
}
