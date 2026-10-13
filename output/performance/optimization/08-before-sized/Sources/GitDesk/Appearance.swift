import AppKit

enum AppTheme: String, CaseIterable {
  case islandDark, islandLight, light, dark
  var title: String {
    switch self {
    case .islandDark: return "Island Dark"
    case .islandLight: return "Island Light"
    case .light: return "Light"
    case .dark: return "Dark"
    }
  }
  var isDark: Bool { self == .dark || self == .islandDark }
  var isIsland: Bool { self == .islandDark || self == .islandLight }
  var appearance: NSAppearance { NSAppearance(named: isDark ? .darkAqua : .aqua)! }
  static func saved(in defaults: UserDefaults = .standard) -> AppTheme {
    defaults.string(forKey: "appearanceTheme").flatMap(AppTheme.init(rawValue:)) ?? .dark
  }

  // Semantic colors follow IDEA's bundled Dark/Light and Islands palettes.
  func color(_ role: ThemeColor) -> NSColor { Self.palettes[self]![role]! }
  private static let palettes = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makePalette()) })
  private func makePalette() -> [ThemeColor: NSColor] {
    let dark: [ThemeColor: UInt32] = [
      .background: 0x1E1F22, .chrome: 0x2B2D30, .line: 0x393B40,
      .border: 0x43454A, .text: 0xDFE1E5, .muted: 0x868A91,
      .selection: 0x25324D, .activeSelection: 0x2E436E, .inactiveSelection: 0x43454A,
      .blue: 0x6B9BFA, .green: 0x89CC8E, .red: 0xE37774, .yellow: 0xF2C55C,
      .accent: 0x3574F0, .pressedAccent: 0x315FBC,
      .diffRemoved: 0x422D30, .diffAdded: 0x2D4435, .diffModified: 0x2D3E52,
      .diffGap: 0x23262B, .keyword: 0xCF8E6D, .string: 0x6AAB73, .heading: 0xC77DBB,
    ]
    let light: [ThemeColor: UInt32] = [
      .background: 0xFFFFFF, .chrome: 0xF7F8FA, .line: 0xDFE1E5,
      .border: 0xC9CCD6, .text: 0x27282E, .muted: 0x6C707E,
      .selection: 0xEDF3FF, .activeSelection: 0xD4E2FF, .inactiveSelection: 0xEBECF0,
      .blue: 0x315FBD, .green: 0x1F7536, .red: 0xBC303E, .yellow: 0xA46704,
      .accent: 0x3574F0, .pressedAccent: 0x2E55A3,
      .diffRemoved: 0xFCE6E6, .diffAdded: 0xE1F2DF, .diffModified: 0xDFEAFB,
      .diffGap: 0xF0F1F2, .keyword: 0x0033B3, .string: 0x067D17, .heading: 0x871094,
    ]
    var palette = isDark ? dark : light
    if isIsland {
      palette[.chrome] = isDark ? 0x26282C : 0xE9EAEE
      palette[.background] = isDark ? 0x191A1C : 0xFFFFFF
      palette[.line] = isDark ? 0x26282C : 0xE9EAEE
      palette[.border] = isDark ? 0x40434A : 0xD1D3D9
      palette[.text] = isDark ? 0xD1D3D9 : 0x000000
      palette[.muted] = 0x73767C
      palette[.activeSelection] = isDark ? 0x2A4371 : 0xD0DFFE
      palette[.inactiveSelection] = isDark ? 0x33353B : 0xE9EAEE
      palette[.blue] = isDark ? 0x71A1FE : 0x2F5EB9
      palette[.green] = isDark ? 0x6DB083 : 0x338555
      palette[.red] = isDark ? 0xF57E84 : 0xC54E58
      palette[.yellow] = isDark ? 0xD59637 : 0xA56906
      palette[.accent] = 0x3871E1
    }
    var colors = palette.mapValues { NSColor(hex: $0) }
    colors[.hover] = (isDark ? NSColor.white : NSColor.black).withAlphaComponent(isDark ? 0.063 : 0.04)
    return colors
  }
}

enum ThemeColor: String {
  case background, chrome, line, border, text, muted, selection, activeSelection, inactiveSelection
  case hover, blue, green, red, yellow, accent, pressedAccent
  case diffRemoved, diffAdded, diffModified, diffGap, keyword, string, heading
}

extension Theme {
  static let didChange = Notification.Name("GitDeskThemeDidChange")
  static func dynamic(_ role: ThemeColor) -> NSColor {
    NSColor(name: NSColor.Name("GitDesk." + role.rawValue)) { _ in current.color(role) }
  }
  static func apply(_ theme: AppTheme, persist: Bool = true) {
    current = theme
    if persist { UserDefaults.standard.set(theme.rawValue, forKey: "appearanceTheme") }
    NSApp.appearance = theme.appearance
    NotificationCenter.default.post(name: didChange, object: nil)
    for window in NSApp.windows {
      window.appearance = nil
      window.backgroundColor = chrome
      if let content = window.contentView { refresh(content) }
      if window.styleMask.contains(.titled) {
        for accessory in window.titlebarAccessoryViewControllers { refresh(accessory.view) }
      }
      window.displayIfNeeded()
    }
  }
  static func refresh(_ view: NSView) {
    (view as? ThemeUpdating)?.refreshTheme()
    if let split = view as? NSSplitView { split.adjustSubviews() }
    // Reassign semantic colors to invalidate AppKit's cached control/text drawing.
    if let field = view as? NSTextField {
      field.textColor = field.textColor
      if field.currentEditor() == nil { field.attributedStringValue = field.attributedStringValue }
    }
    if let button = view as? NSButton { button.contentTintColor = button.contentTintColor }
    if let image = view as? NSImageView { image.contentTintColor = image.contentTintColor }
    if let text = view as? NSTextView {
      text.backgroundColor = text.backgroundColor
      text.insertionPointColor = blue
      text.selectedTextAttributes = [.backgroundColor: activeSelection, .foregroundColor: self.text]
      text.layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: text.string.utf16.count))
    }
    if let table = view as? NSTableView { table.backgroundColor = background }
    if let scroll = view as? NSScrollView { scroll.backgroundColor = background }
    view.needsDisplay = true
    view.subviews.forEach(refresh)
  }
}

final class ThemeMenu: NSMenu, NSMenuDelegate {
  init() {
    super.init(title: "Theme")
    delegate = self
    for theme in AppTheme.allCases {
      let item = menuItem(theme.title) { Theme.apply(theme) }
      addItem(item)
    }
  }
  required init(coder: NSCoder) { fatalError() }
  func menuNeedsUpdate(_ menu: NSMenu) {
    for (item, theme) in zip(items, AppTheme.allCases) { item.state = Theme.current == theme ? .on : .off }
  }
}

final class AppearanceWindowController: NSWindowController {
  let themePopup = NSPopUpButton()
  private var observer: NSObjectProtocol?
  init() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 330),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "Settings"
    window.isReleasedWhenClosed = false
    let content = Surface(Theme.chrome)
    window.contentView = content
    let sidebar = Surface()
    let category = label("Appearance & Behavior", bold: true)
    let selected = Surface(Theme.activeSelection)
    selected.layer?.cornerRadius = 5
    pin(label("Appearance"), to: selected, inset: 8)
    let navigation = NSStackView(views: [category, selected, NSView()])
    navigation.orientation = .vertical
    navigation.alignment = .leading
    navigation.spacing = 14
    pin(navigation, to: sidebar, inset: 16)
    selected.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true
    let pane = Surface()
    let heading = label("Appearance", size: 18, bold: true)
    themePopup.addItems(withTitles: AppTheme.allCases.map(\.title))
    themePopup.selectItem(at: AppTheme.allCases.firstIndex(of: Theme.current)!)
    themePopup.target = self
    themePopup.action = #selector(themeChanged)
    themePopup.setAccessibilityLabel("Theme")
    themePopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
    let themeRow = row([label("Theme:"), themePopup], spacing: 16)
    let hint = label("Applies immediately to all GitDesk windows.", color: Theme.muted, size: 12)
    let note = label("Island themes use a rounded tool window.\nInternal panes use thin dividers.", color: Theme.muted, size: 12)
    note.maximumNumberOfLines = 2
    let stack = NSStackView(views: [heading, themeRow, hint, note, NSView()])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 24
    pin(stack, to: pane, inset: 28)
    let layout = row([sidebar, pane], spacing: 1)
    layout.alignment = .height
    pin(layout, to: content)
    sidebar.widthAnchor.constraint(equalToConstant: 215).isActive = true
    pane.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -216).isActive = true
    observer = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) {
      [weak self] _ in self?.themePopup.selectItem(at: AppTheme.allCases.firstIndex(of: Theme.current)!)
    }
    window.center()
  }
  required init?(coder: NSCoder) { fatalError() }
  deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
  @objc func themeChanged() {
    guard AppTheme.allCases.indices.contains(themePopup.indexOfSelectedItem) else { return }
    Theme.apply(AppTheme.allCases[themePopup.indexOfSelectedItem])
  }
  func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil) }
}
