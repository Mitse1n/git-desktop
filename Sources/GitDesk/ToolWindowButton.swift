import AppKit

/// IntelliJ's stripe uses a 40-point target, a centered 20-point icon,
/// and a selected background inset by 5 points.
final class ToolWindowButton: NSButton, ThemeUpdating {
  var iconName: String { didSet { refreshTheme() } }
  var selected = false { didSet { needsDisplay = true; setAccessibilityValue(selected ? 1 : 0) } }
  private var hovered = false
  private var handler: () -> Void
  private var tracking: NSTrackingArea?

  init(icon: String, tooltip: String, action: @escaping () -> Void) {
    iconName = icon
    handler = action
    super.init(frame: .zero)
    title = ""
    isBordered = false
    imagePosition = .imageOnly
    toolTip = tooltip
    setAccessibilityLabel(tooltip)
    target = self
    self.action = #selector(invoke)
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 40),
      heightAnchor.constraint(equalToConstant: 40),
    ])
    refreshTheme()
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc private func invoke() { handler() }

  func refreshTheme() {
    let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("assets/tool-window-icons")
    let roots = [Bundle.main.resourceURL?.appendingPathComponent("ToolWindowIcons"), development].compactMap { $0 }
    let variant = iconName + (Theme.current.isDark ? "_dark" : "") + ".svg"
    image = roots.lazy.compactMap { NSImage(contentsOf: $0.appendingPathComponent(variant)) }.first
    image?.size = NSSize(width: 20, height: 20)
    image?.isTemplate = false
    needsDisplay = true
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }
  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    if selected || hovered || isHighlighted {
      (selected || isHighlighted ? Theme.selection : Theme.hover).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 5), xRadius: 6, yRadius: 6).fill()
    }
    image?.draw(in: NSRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20),
      from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.4, respectFlipped: true, hints: nil)
  }
}
