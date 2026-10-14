import AppKit
import CoreText
import GitDeskCore

/// Load the same editor family as IDEA without depending on an IDEA installation.
enum DiffFont {
  private static let registration: Void = {
    let sourceAssets = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("assets/fonts")
    let bundled = Bundle.main.resourceURL?.appendingPathComponent("Fonts")
    for name in ["JetBrainsMono-Regular", "JetBrainsMono-Italic"] {
      let locations = [bundled, sourceAssets].compactMap { $0?.appendingPathComponent(name + ".ttf") }
      if let url = locations.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
      }
    }
  }()
  static func regular(_ size: CGFloat = 13) -> NSFont {
    _ = registration
    return NSFont(name: "JetBrainsMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
  }
  static func italic(_ size: CGFloat = 13) -> NSFont {
    _ = registration
    return NSFont(name: "JetBrainsMono-Italic", size: size)
      ?? NSFontManager.shared.convert(regular(size), toHaveTrait: .italicFontMask)
  }
}

/// Lex the original document so block comments and multiline strings survive diff gaps.
/// Store ranges, not attributed strings, to keep the diff's memory bounded.
enum DiffSyntax {
  enum TokenKind { case keyword, string, comment, number, type, heading, headingMarker, tag }
  struct Token { let range: NSRange; let kind: TokenKind }
  static func tokens(_ data: Data, path: String, shouldCancel: () -> Bool = { false }) -> [[Token]] {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    let hashComments = ["py", "rb", "sh", "bash", "zsh", "yaml", "yml", "toml"].contains(ext)
    let supported = ["swift", "java", "kt", "kts", "js", "jsx", "ts", "tsx", "json", "jsonc", "go", "rs", "c", "h", "cpp", "hpp", "cs", "css", "scss", "sql", "py", "rb", "sh", "bash", "zsh", "yaml", "yml", "toml", "md", "xml", "html", "vue", "svelte"]
    guard supported.contains(ext), !shouldCancel() else { return [] }
    let source = String(decoding: data, as: UTF8.self)
    let lines = source.components(separatedBy: "\n")
    var result = Array(repeating: [Token](), count: lines.count)
    let keywords = "import|package|namespace|using|struct|class|interface|enum|extension|protocol|func|fun|function|def|let|var|val|const|public|private|protected|internal|static|final|open|override|mutating|async|await|throws|rethrows|return|if|else|guard|throw|try|catch|finally|case|switch|when|for|while|do|break|continue|in|of|as|is|new|this|self|super|nil|null|None|true|false|True|False|void|int|bool|boolean|double|float|long|char|type|typealias|where|some|any|actor|defer|init|deinit|weak|unowned|default|export|from|extends|implements|fn|pub|impl|use|mod|match|elif|except|with|lambda|pass|and|or|not|SELECT|FROM|WHERE|JOIN|INSERT|UPDATE|DELETE|CREATE|TABLE|ORDER|BY|AS|AND|OR|NULL"
    let comment = ext == "sql" ? "--[^\\n]*" : hashComments ? "#[^\\n]*" : "//[^\\n]*"
    let patterns: [(String, TokenKind)] = [
      ("(?s:/\\*.*?(?:\\*/|\\z)|<!--.*?(?:-->|\\z))|" + comment, .comment),
      (#"(?s:""".*?(?:"""|\z)|'''.*?(?:'''|\z)|`(?:\\.|[^`])*(?:`|\z))|"(?:\\.|[^"\\\n])*(?:"|$)|'(?:\\.|[^'\\\n])*(?:'|$)"#, .string),
      ("\\b(?:" + keywords + ")\\b", .keyword),
      (#"\b(?:0[xX][\da-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#, .number),
      (#"\b[A-Z][A-Za-z_0-9]*\b"#, .type),
    ]
    let markdown: [(String, TokenKind)] = [("(?m)^#{1,6}[^\\n]*", .heading), (#"`[^`\n]*`"#, .string)]
    let xml: [(String, TokenKind)] = [
      (#"(?s:<!--.*?(?:-->|\z)|<!\[CDATA\[.*?(?:\]\]>|\z))"#, .comment),
      (#""[^"]*"|'[^']*'"#, .string),
      (#"</?[A-Za-z_:][\w:.-]*|<\?[A-Za-z_:][\w:.-]*|<![A-Za-z]+|\?>|/?>"#, .tag),
    ]
    let rules = ext == "md" ? markdown : ["xml", "html"].contains(ext) ? xml : patterns
    // One alternation consumes each token once: keywords inside strings/comments stay untouched.
    guard let regex = try? NSRegularExpression(pattern: rules.map { "(" + $0.0 + ")" }.joined(separator: "|"), options: .anchorsMatchLines) else { return result }
    var starts: [Int] = []; var offset = 0
    for line in lines { starts.append(offset); offset += (line as NSString).length + 1 }
    var lineIndex = 0
    regex.enumerateMatches(in: source, range: NSRange(location: 0, length: (source as NSString).length)) { match, _, stop in
      if shouldCancel() { stop.pointee = true; return }
      guard let match, let rule = rules.indices.first(where: { match.range(at: $0 + 1).location != NSNotFound }) else { return }
      while lineIndex + 1 < starts.count && starts[lineIndex + 1] <= match.range.location { lineIndex += 1 }
      var i = lineIndex
      while i < lines.count && starts[i] < NSMaxRange(match.range) {
        let intersection = NSIntersectionRange(match.range, NSRange(location: starts[i], length: (lines[i] as NSString).length))
        if intersection.length > 0 { result[i].append(Token(range: NSRange(location: intersection.location - starts[i], length: intersection.length), kind: rules[rule].1)) }
        i += 1
      }
    }
    if ext == "md" {
      for i in lines.indices where result[i].contains(where: { $0.kind == .heading }) {
        let count = lines[i].prefix(while: { $0 == "#" }).count
        if count > 0 { result[i].append(Token(range: NSRange(location: 0, length: count), kind: .headingMarker)) }
      }
    }
    return result
  }
  static func color(_ kind: TokenKind) -> NSColor {
    switch kind {
    case .keyword: return Theme.keyword
    case .string: return Theme.string
    case .comment: return Theme.muted
    case .number: return Theme.yellow
    case .type: return Theme.blue
    case .heading: return Theme.heading
    case .headingMarker: return Theme.keyword
    case .tag: return NSColor(name: "GitDesk.xmlTag") { _ in NSColor(hex: Theme.current.isDark ? 0xD6B56D : 0x000080) }
    }
  }
  /// Highlight separate edits without painting unchanged words between them.
  /// Bound the quadratic comparison for generated/minified lines.
  static func changedSegments(_ left: String, _ right: String) -> ([NSRange], [NSRange]) {
    let a = Array(left), b = Array(right)
    guard a.count <= 2048, b.count <= 2048, a.count * b.count <= 250_000 else {
      let ranges = changedRanges(left, right)
      return ([ranges.0].filter { $0.length > 0 }, [ranges.1].filter { $0.length > 0 })
    }
    var removed = IndexSet(), added = IndexSet()
    for change in b.difference(from: a) {
      switch change {
      case .remove(let offset, _, _): removed.insert(offset)
      case .insert(let offset, _, _): added.insert(offset)
      }
    }
    func ranges(_ indices: IndexSet, _ chars: [Character]) -> [NSRange] {
      var offsets = [0]
      for char in chars { offsets.append(offsets.last! + String(char).utf16.count) }
      return indices.rangeView.map { NSRange(location: offsets[$0.lowerBound],
        length: offsets[$0.upperBound] - offsets[$0.lowerBound]) }
    }
    return (ranges(removed, a), ranges(added, b))
  }
  /// Character boundaries keep emoji and combining characters intact.
  static func changedRanges(_ left: String, _ right: String) -> (NSRange, NSRange) {
    let a = Array(left), b = Array(right)
    var prefix = 0, suffix = 0
    while prefix < min(a.count, b.count) && a[prefix] == b[prefix] { prefix += 1 }
    while suffix < min(a.count, b.count) - prefix && a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
    func range(_ chars: [Character]) -> NSRange {
      NSRange(location: String(chars.prefix(prefix)).utf16.count,
        length: String(chars[prefix..<(chars.count - suffix)]).utf16.count)
    }
    return (range(a), range(b))
  }
}

/// Opaque cells draw selection above diff tint, so selected lines remain visible.
final class DiffCell: NSView, ThemeUpdating {
  let field = label("")
  private var fieldLeading: NSLayoutConstraint!
  var textInset: CGFloat = 3 { didSet { fieldLeading.constant = textInset } }
  var baseColor = DiffPalette.background { didSet { needsDisplay = true } }
  var selected = false { didSet { needsDisplay = true } }
  override init(frame: NSRect) {
    super.init(frame: frame)
    field.lineBreakMode = .byClipping
    field.usesSingleLineMode = true
    field.translatesAutoresizingMaskIntoConstraints = false; addSubview(field)
    fieldLeading = field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3)
    NSLayoutConstraint.activate([fieldLeading, field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
      field.topAnchor.constraint(equalTo: topAnchor, constant: 3), field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)])
  }
  convenience init() { self.init(frame: .zero) }
  required init?(coder: NSCoder) { fatalError() }
  func refreshTheme() { needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    baseColor.setFill(); bounds.fill()
    if selected { Theme.selection.withAlphaComponent(0.65).setFill(); bounds.fill() }
  }
}

final class DiffTable: NSTableView {
  override var backgroundColor: NSColor {
    get { super.backgroundColor }
    set { super.backgroundColor = DiffPalette.background }
  }
  var copyText: ((Bool) -> String)?
  var navigateDifference: ((Int) -> Void)?
  var findRequested: (() -> Void)?
  var reviewCommentRequested: (() -> Void)?
  var bottomPadding: CGFloat = 0
  var navigationOnlySelection = false { didSet { if oldValue != navigationOnlySelection { reloadData() } } }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(NSSize(width: newSize.width, height: max(newSize.height, CGFloat(numberOfRows) * rowHeight + bottomPadding)))
  }
  @objc func copy(_ sender: Any?) { copySide(false) }
  func copySide(_ left: Bool) {
    guard !selectedRowIndexes.isEmpty, let text = copyText?(left) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
  override func mouseDown(with event: NSEvent) {
    navigationOnlySelection = false
    super.mouseDown(with: event)
  }
  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "f" { findRequested?(); return }
    if event.keyCode == 98 { navigateDifference?(event.modifierFlags.contains(.shift) ? -1 : 1); return }
    navigationOnlySelection = false
    super.keyDown(with: event)
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let index = row(at: convert(event.locationInWindow, from: nil))
    if index >= 0 && !selectedRowIndexes.contains(index) { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    let menu = NSMenu()
    menu.addItem(menuItem("Copy selected lines (right)", enabled: !selectedRowIndexes.isEmpty) { [weak self] in self?.copySide(false) })
    menu.addItem(menuItem("Copy selected lines (left)", enabled: !selectedRowIndexes.isEmpty) { [weak self] in self?.copySide(true) })
    if reviewCommentRequested != nil {
      menu.addItem(.separator())
      menu.addItem(menuItem("Comment on This Line…", enabled: selectedRowIndexes.count == 1) { [weak self] in self?.reviewCommentRequested?() })
    }
    return menu
  }
}

/// A change is a range in each original document, never a collection of row triangles.
struct DiffHunk {
  let left: Range<Int>
  let right: Range<Int>
  var color: NSColor { left.isEmpty ? DiffPalette.added : right.isEmpty ? Theme.diffRemoved : Theme.diffModified }
  static func build(_ rows: [DiffLine]) -> [DiffHunk] {
    var result: [DiffHunk] = [], l = 0, r = 0, index = 0
    while index < rows.count {
      if rows[index].kind == .unchanged {
        if rows[index].left != nil { l += 1 }; if rows[index].right != nil { r += 1 }
        index += 1; continue
      }
      let startL = l, startR = r
      while index < rows.count && rows[index].kind != .unchanged {
        if rows[index].left != nil { l += 1 }; if rows[index].right != nil { r += 1 }
        index += 1
      }
      result.append(DiffHunk(left: startL..<l, right: startR..<r))
    }
    return result
  }
  static func containing(_ line: Int, in hunks: [DiffHunk], left: Bool) -> DiffHunk? {
    var low = 0, high = hunks.count
    while low < high {
      let mid = (low + high) / 2
      if (left ? hunks[mid].left : hunks[mid].right).lowerBound <= line { low = mid + 1 }
      else { high = mid }
    }
    guard low > 0 else { return nil }
    let hunk = hunks[low - 1]
    return (left ? hunk.left : hunk.right).contains(line) ? hunk : nil
  }
  static func map(_ position: CGFloat, hunks: [DiffHunk], fromLeft: Bool) -> CGFloat {
    var sourceEnd: CGFloat = 0, targetEnd: CGFloat = 0
    for hunk in hunks {
      let source = fromLeft ? hunk.left : hunk.right
      let target = fromLeft ? hunk.right : hunk.left
      let start = CGFloat(source.lowerBound), end = CGFloat(source.upperBound)
      let targetStart = CGFloat(target.lowerBound), targetStop = CGFloat(target.upperBound)
      if position < start { return targetEnd + position - sourceEnd }
      if position < end { return targetStart + (position - start) / max(1, end - start) * (targetStop - targetStart) }
      sourceEnd = end; targetEnd = targetStop
    }
    return targetEnd + position - sourceEnd
  }
}
enum DiffPalette {
  static let chrome = NSColor(name: "GitDesk.diff.chrome") { _ in
    Theme.current.isDark ? NSColor(hex: 0x212326) : Theme.chrome
  }
  static let chromeBorder = NSColor(name: "GitDesk.diff.chromeBorder") { _ in
    Theme.current.isDark ? NSColor(hex: 0x26282C) : Theme.border
  }
  static let background = NSColor(name: "GitDesk.diff.background") { _ in
    Theme.current.isDark ? NSColor(hex: 0x191A1C) : Theme.background
  }
  static let text = NSColor(name: "GitDesk.diff.text") { _ in
    Theme.current.isDark ? NSColor(hex: 0xBCBEC4) : Theme.text
  }
  static let line = NSColor(name: "GitDesk.diff.line") { _ in
    Theme.current.isDark ? NSColor(hex: 0x323438) : Theme.line
  }
  static let added = NSColor(name: "GitDesk.diff.added") { _ in
    Theme.current.isDark ? NSColor(hex: 0x294436) : Theme.diffAdded
  }
  static let gutter = NSColor(name: "GitDesk.diff.gutter") { _ in
    Theme.current.isDark ? NSColor(hex: 0x4B5059) : Theme.muted
  }
  static let caret = NSColor(name: "GitDesk.diff.caret") { _ in
    Theme.current.isDark ? NSColor(hex: 0xA1A3AB) : Theme.text
  }
}
final class DiffDivider: NSView, ThemeUpdating {
  var hunks: [DiffHunk] = []
  var leftOffset: CGFloat = 0, rightOffset: CGFloat = 0
  var rowHeight: CGFloat = 22
  override var isFlipped: Bool { true }
  func refreshTheme() { needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    bounds.clip()
    DiffPalette.background.setFill(); bounds.fill()
    for h in hunks {
      let l0 = CGFloat(h.left.lowerBound) * rowHeight - leftOffset - (h.left.isEmpty ? 1 : 0)
      let l1 = max(l0 + 1, CGFloat(h.left.upperBound) * rowHeight - leftOffset)
      let r0 = CGFloat(h.right.lowerBound) * rowHeight - rightOffset - (h.right.isEmpty ? 1 : 0)
      let r1 = max(r0 + 1, CGFloat(h.right.upperBound) * rowHeight - rightOffset)
      guard max(l1, r1) >= 0, min(l0, r0) <= bounds.height else { continue }
      let path = NSBezierPath(), w = bounds.width
      path.move(to: NSPoint(x: 0, y: l0))
      path.curve(to: NSPoint(x: w, y: r0), controlPoint1: NSPoint(x: w * 0.3, y: l0), controlPoint2: NSPoint(x: w * 0.7, y: r0))
      path.line(to: NSPoint(x: w, y: r1))
      path.curve(to: NSPoint(x: 0, y: l1), controlPoint1: NSPoint(x: w * 0.7, y: r1), controlPoint2: NSPoint(x: w * 0.3, y: l1))
      path.close(); h.color.setFill(); path.fill()
    }
  }
}
final class DiffGutter: NSView, ThemeUpdating {
  var count = 0, offset: CGFloat = 0, rowHeight: CGFloat = 22
  var hunks: [DiffHunk] = [], left = true
  var caretLine: Int?
  override var isFlipped: Bool { true }
  func refreshTheme() { needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    bounds.clip()
    DiffPalette.background.setFill(); bounds.fill()
    DiffPalette.line.setFill()
    NSRect(x: left ? 0 : bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    let first = max(0, Int(offset / rowHeight)), last = min(count, Int((offset + bounds.height) / rowHeight) + 1)
    guard first < last else { return }
    let font = DiffFont.regular()
    for i in first..<last {
      let y = CGFloat(i) * rowHeight - offset
      let change = DiffHunk.containing(i, in: hunks, left: left)
      if let change { change.color.setFill(); NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).fill() }
      let text = "\(i + 1)" as NSString
      let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: i == caretLine ? DiffPalette.caret : DiffPalette.gutter]
      let width = text.size(withAttributes: attrs).width
      text.draw(at: NSPoint(x: bounds.width - width - (left ? 15 : 21), y: y + 3), withAttributes: attrs)
    }
  }
}
final class DiffOverview: NSView, ThemeUpdating {
  var hunks: [DiffHunk] = [], count = 0
  var documentHeight: CGFloat = 0
  var singleSide = false
  private var documentLines: CGFloat { max(CGFloat(count), bounds.height / 22) }
  var jump: ((Int) -> Void)?
  override var isFlipped: Bool { true }
  func refreshTheme() { needsDisplay = true }
  func markerRect(for hunk: DiffHunk) -> NSRect {
    let range = hunk.right.isEmpty ? hunk.left : hunk.right
    let y: CGFloat, height: CGFloat
    if singleSide {
      y = CGFloat(range.lowerBound) / documentLines * bounds.height
      height = max(3, CGFloat(range.count) / documentLines * bounds.height)
    } else {
      // Reserve the status/control areas, then map original document offsets.
      let trackHeight = max(1, bounds.height - 36 - 8)
      let scale = min(1, trackHeight / max(1, documentHeight))
      y = 36 + floor(CGFloat(range.lowerBound) * 22 * scale)
      let lastLine = max(range.lowerBound, range.upperBound - 1)
      let end = 36 + ceil(CGFloat(lastLine) * 22 * scale)
      height = max(3, end - y)
    }
    return NSRect(x: 0, y: y, width: bounds.width, height: height)
  }
  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    bounds.clip()
    guard count > 0 else { return }
    for hunk in hunks {
      let marker = hunk.left.isEmpty ? (Theme.current.isDark ? NSColor(hex: 0x5F866A) : Theme.green)
        : hunk.right.isEmpty ? Theme.red : Theme.blue
      marker.setFill(); markerRect(for: hunk).fill()
    }
  }
  override func mouseDown(with event: NSEvent) {
    let y = convert(event.locationInWindow, from: nil).y
    if let closest = hunks.indices.min(by: {
      abs(markerRect(for: hunks[$0]).midY - y) < abs(markerRect(for: hunks[$1]).midY - y)
    }) { jump?(closest) }
  }

}

/// Pane frames are shared by the revision header and the editor, so labels stay aligned.
final class DiffEditorLayout: NSView {
  let mainScroll: NSScrollView, rightScroll: NSScrollView
  let leftGutter = DiffGutter(), rightGutter = DiffGutter()
  let divider = DiffDivider(), overview = DiffOverview()
  let leftBoundary = DiffBoundaryOverlay(), rightBoundary = DiffBoundaryOverlay()
  let leftThumb = DiffScrollThumb(), rightThumb = DiffScrollThumb()
  var split = true { didSet { needsLayout = true } }
  init(main: NSTableView, right: NSTableView) {
    mainScroll = scrollView(main); rightScroll = scrollView(right)
    super.init(frame: .zero)
    // Plain NSViews do not clip their descendants by default on macOS 14+.
    // Offscreen hunk endpoints must never paint over sibling toolbar/header views.
    clipsToBounds = true
    for scroll in [mainScroll, rightScroll] {
      scroll.hasVerticalScroller = false
      scroll.scrollerStyle = .overlay
      scroll.backgroundColor = DiffPalette.background
    }
    leftThumb.scroll = mainScroll; rightThumb.scroll = rightScroll
    rightGutter.left = false
    rightBoundary.left = false
    for child in [mainScroll, leftGutter, divider, rightGutter, rightScroll, overview, leftBoundary, rightBoundary, leftThumb, rightThumb] {
      child.clipsToBounds = true
      addSubview(child)
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    let width = max(0, bounds.width - 5), height = bounds.height
    for child in [leftGutter, divider, rightGutter, rightScroll, leftBoundary, rightBoundary] { child.isHidden = !split }
    if split {
      let pane = max(0, (width - 112) / 2)
      mainScroll.frame = NSRect(x: 0, y: 0, width: pane, height: height)
      leftGutter.frame = NSRect(x: pane, y: 0, width: 44, height: height)
      divider.frame = NSRect(x: pane + 44, y: 0, width: 24, height: height)
      rightGutter.frame = NSRect(x: pane + 68, y: 0, width: 44, height: height)
      rightScroll.frame = NSRect(x: pane + 112, y: 0, width: pane, height: height)
    } else { mainScroll.frame = NSRect(x: 0, y: 0, width: width, height: height) }
    leftBoundary.frame = NSRect(x: 0, y: 0, width: mainScroll.frame.width + (split ? leftGutter.frame.width : 0), height: height)
    rightBoundary.frame = rightScroll.frame
    leftThumb.isHidden = !split
    leftThumb.frame = NSRect(x: 1.5, y: 0, width: 7.5, height: height)
    rightThumb.scroll = split ? rightScroll : mainScroll
    rightThumb.frame = NSRect(x: bounds.width - 14.5, y: 0, width: 7.5, height: height)
    overview.frame = NSRect(x: bounds.width - 18, y: 0, width: 12, height: height)
  }
}

/// Mark a zero-length insertion/deletion without reserving blank document rows.
final class DiffBoundaryOverlay: NSView, ThemeUpdating {
  var left = true, offset: CGFloat = 0
  var hunks: [DiffHunk] = []
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  func refreshTheme() { needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    bounds.clip()
    for hunk in hunks {
      let range = left ? hunk.left : hunk.right
      if range.isEmpty {
        let y = CGFloat(range.lowerBound) * 22 - offset
        hunk.color.setFill()
        NSRect(x: left ? 17 : 0, y: y - 1, width: bounds.width - 17, height: 2).fill()
        NSColor(hex: Theme.current.isDark ? 0x375642 : 0x549159).setFill()
        NSRect(x: left ? 1 : bounds.width - 12, y: y - 8, width: 11, height: 2).fill()
      }
    }
  }
}

final class DiffLayoutControl: NSSegmentedControl {
  override var intrinsicContentSize: NSSize { NSSize(width: 88, height: 30) }
  override func draw(_ dirtyRect: NSRect) {
    let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
    Theme.border.setStroke(); border.lineWidth = 1; border.stroke()
    for i in 0..<2 {
      let rect = NSRect(x: CGFloat(i) * bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height)
      if selectedSegment == i {
        let selected = NSBezierPath(roundedRect: rect.insetBy(dx: 0.8, dy: 0.8), xRadius: 4, yRadius: 4)
        Theme.border.setStroke(); selected.lineWidth = 1.5; selected.stroke()
      }
      let symbol = NSImage(systemSymbolName: i == 0 ? "rectangle.split.2x1" : "rectangle", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
          .applying(NSImage.SymbolConfiguration(paletteColors: [isEnabled ? DiffPalette.text : Theme.muted])))
      symbol?.draw(in: NSRect(x: rect.midX - 8, y: rect.midY - 7, width: 16, height: 14))
    }
  }
}

/// Keep the file-count caption stable while the native popup menu selects a path.
final class DiffFilePickerCell: NSPopUpButtonCell {
  var caption = "1 file"
  override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
    let text = caption as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.muted]
    let size = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: cellFrame.minX + 3, y: cellFrame.midY - size.height / 2), withAttributes: attributes)
  }
}

/// Overlay thumbs are positioned on the outside edges, as in IDEA's two editors.
final class DiffScrollThumb: NSView {
  weak var scroll: NSScrollView?
  override var isFlipped: Bool { true }
  private var knob: NSRect {
    guard let scroll else { return .zero }
    let document = max(scroll.contentSize.height, scroll.documentView?.frame.height ?? 0)
    if document <= scroll.contentSize.height + 1 {
      return NSRect(x: 0, y: 2, width: bounds.width, height: max(0, bounds.height - 7))
    }
    let trackHeight = max(0, bounds.height - 4)
    let height = max(18, trackHeight * scroll.contentSize.height / document)
    let travel = max(0, trackHeight - height)
    let ratio = scroll.contentView.bounds.minY / max(1, document - scroll.contentSize.height)
    return NSRect(x: 0, y: 2 + max(0, min(travel, ratio * travel)), width: bounds.width, height: height)
  }
  override func draw(_ dirtyRect: NSRect) {
    guard !knob.isEmpty else { return }
    (Theme.current.isDark ? NSColor.white.withAlphaComponent(0.15) : NSColor.black.withAlphaComponent(0.2)).setFill()
    NSBezierPath(roundedRect: knob, xRadius: bounds.width / 2, yRadius: bounds.width / 2).fill()
  }
  override func hitTest(_ point: NSPoint) -> NSView? { knob.isEmpty ? nil : super.hitTest(point) }
  override func mouseDown(with event: NSEvent) {
    guard let scroll, let window else { return }
    let start = convert(event.locationInWindow, from: nil).y
    let original = knob
    let grabbed = original.contains(NSPoint(x: bounds.midX, y: start))
    let relative = grabbed ? start - original.minY : original.height / 2
    func move(_ y: CGFloat) {
      let document = max(scroll.contentSize.height, scroll.documentView?.frame.height ?? 0)
      let fraction = max(0, min(1, (y - relative - 2) / max(1, bounds.height - 4 - original.height)))
      scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: fraction * (document - scroll.contentSize.height)))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    if !grabbed { move(start) }
    while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      if next.type == .leftMouseUp { break }
      move(convert(next.locationInWindow, from: nil).y)
    }
  }
}
