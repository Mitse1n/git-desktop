import AppKit
import CoreText

struct LogHoverText {
  let text: String
  let font: NSFont
  let color: NSColor
  let rect: NSRect

  var isTruncated: Bool {
    !text.isEmpty && rect.width > 0
      && ((text as NSString).size(withAttributes: [.font: font]).width > rect.width + 0.5
        || text.contains("\n"))
  }
}

protocol LogExpandableCell: AnyObject {
  var hoverText: LogHoverText? { get }
}

final class LogMetadataCell: NSTableCellView, LogExpandableCell {
  var hoverText: LogHoverText? {
    guard let field = textField, let cell = field.cell else { return nil }
    return LogHoverText(text: field.stringValue, font: field.font ?? .systemFont(ofSize: 13),
      color: field.textColor ?? .labelColor,
      rect: convert(cell.drawingRect(forBounds: field.bounds), from: field))
  }
}

/// Layout is bounded by the owning window, even for a single enormous word or emoji sequence.
struct LogTextExpansionLayout {
  static let padding = NSSize(width: 5, height: 4)
  let frame: NSRect
  let lines: [String]
  let lineHeight: CGFloat
  let font: NSFont

  static func make(text: String, font: NSFont, sourceRect: NSRect,
    containerBounds: NSRect, flipped: Bool) -> LogTextExpansionLayout? {
    let lineHeight = ceil(font.ascender - font.descender + font.leading)
    let maxWidth = floor(containerBounds.width - padding.width * 2)
    let maxLines = Int(floor((containerBounds.height - padding.height * 2) / lineHeight))
    guard !text.isEmpty, maxWidth > 0, maxLines > 0 else { return nil }
    let naturalWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
    let textWidth = min(maxWidth, max(1, naturalWidth))
    let string = text as NSString
    let typesetter = CTTypesetterCreateWithAttributedString(
      NSAttributedString(string: text, attributes: [.font: font]))
    var lines: [String] = []
    var start = 0
    while start < string.length && lines.count < maxLines {
      var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(textWidth))
      // Keep composed characters intact at both normal line breaks and the final truncation.
      if count > 0 && start + count < string.length {
        let cluster = string.rangeOfComposedCharacterSequence(at: start + count)
        count = max(0, cluster.location - start)
      }
      if count == 0 { count = string.rangeOfComposedCharacterSequence(at: start).length }
      count = min(count, string.length - start)
      var line = string.substring(with: NSRange(location: start, length: count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      start += count
      if lines.count == maxLines - 1 && start < string.length {
        while !line.isEmpty
          && ((line + "...") as NSString).size(withAttributes: [.font: font]).width > textWidth {
          line.removeLast()
        }
        line += "..."
      }
      lines.append(line)
    }
    let width = textWidth + padding.width * 2
    let height = min(containerBounds.height,
      max(sourceRect.height, CGFloat(lines.count) * lineHeight) + padding.height * 2)
    let x = min(max(sourceRect.minX - padding.width, containerBounds.minX), containerBounds.maxX - width)
    let preferredY = flipped ? sourceRect.minY - padding.height : sourceRect.maxY + padding.height - height
    let y = min(max(preferredY, containerBounds.minY), containerBounds.maxY - height)
    return LogTextExpansionLayout(frame: NSRect(x: x, y: y, width: width, height: height),
      lines: lines, lineHeight: lineHeight, font: font)
  }
}

/// Lives above the window's panes and lets clicks, context menus, and scrolling reach the log.
final class LogTextExpansionView: NSView {
  let textLayout: LogTextExpansionLayout
  let textColor: NSColor
  let fillColor: NSColor
  let borderColor: NSColor
  override var isFlipped: Bool { true }
  init(layout: LogTextExpansionLayout, textColor: NSColor, fillColor: NSColor, borderColor: NSColor) {
    textLayout = layout
    self.textColor = textColor
    self.fillColor = fillColor
    self.borderColor = borderColor
    super.init(frame: layout.frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel(layout.lines.joined(separator: "\n"))
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    fillColor.setFill()
    bounds.fill()
    borderColor.setStroke()
    NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: bounds.insetBy(dx: LogTextExpansionLayout.padding.width,
      dy: LogTextExpansionLayout.padding.height)).addClip()
    for (index, line) in textLayout.lines.enumerated() {
      (line as NSString).draw(at: NSPoint(x: LogTextExpansionLayout.padding.width,
        y: LogTextExpansionLayout.padding.height + CGFloat(index) * textLayout.lineHeight),
        withAttributes: [.font: textLayout.font, .foregroundColor: textColor])
    }
    NSGraphicsContext.restoreGraphicsState()
  }
}
