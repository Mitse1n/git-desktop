import AppKit

/// IntelliJ's stripe uses a 40-point target, a centered 20-point icon,
/// and a selected background inset by 5 points.
final class ToolWindowButton: NSButton, ThemeUpdating {
  var iconName: String { didSet { refreshTheme() } }
  var showsActivityBadge = false { didSet { needsDisplay = true } }
  var selected = false { didSet { needsDisplay = true; setAccessibilityValue(selected ? 1 : 0) } }
  private let iconSize: CGFloat
  private let buttonSize: CGFloat
  private var hovered = false
  private var handler: () -> Void
  private var tracking: NSTrackingArea?

  init(icon: String, tooltip: String, size: CGFloat = 40, iconSize: CGFloat = 20, action: @escaping () -> Void) {
    self.iconSize = iconSize
    buttonSize = size
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
      widthAnchor.constraint(equalToConstant: size),
      heightAnchor.constraint(equalToConstant: size),
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
    image?.size = NSSize(width: iconSize, height: iconSize)
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
      NSBezierPath(roundedRect: bounds.insetBy(dx: buttonSize == 40 ? 5 : 3, dy: buttonSize == 40 ? 5 : 3), xRadius: 6, yRadius: 6).fill()
    }
    image?.draw(in: NSRect(x: bounds.midX - iconSize / 2, y: bounds.midY - iconSize / 2, width: iconSize, height: iconSize),
      from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.4, respectFlipped: true, hints: nil)
    if showsActivityBadge {
      Theme.green.setFill()
      NSBezierPath(ovalIn: NSRect(x: bounds.midX + 3, y: bounds.midY - 9, width: 6, height: 6)).fill()
    }
  }
}
