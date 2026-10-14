import AppKit
import GitDeskCore

/// AppKit counterpart of IDEA's searchable action + reference tree popup.
/// Keep its selection/expansion independent of the Log branch filter.
final class BranchPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate, NSWindowDelegate {
  struct Entry {
    var title: String
    var detail = ""
    var symbol: String?
    var branch: Branch?
    var action: (() -> Void)?
    var path: String?
    var depth = 0
    var expanded = false
    var separator = false
    var enabled = true
  }
  private weak var owner: RepositoryController?
  private let panel = BranchPickerPanel(contentRect: .zero,
    styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
  let search = FlatSearchField(frame: .zero)
  let table = BranchPickerTable()
  private(set) var entries: [Entry] = []
  private var collapsed = Set<String>()
  private var monitor: Any?
  private var trackingMenu = false
  private var grouped = UserDefaults.standard.object(forKey: "branchPickerGroupDirectories") as? Bool ?? true
  private var showTags = UserDefaults.standard.object(forKey: "branchPickerShowTags") as? Bool ?? false
  private var actions: [Entry] = []
  private var lastQuery = ""

  init(owner: RepositoryController) {
    self.owner = owner
    super.init()
    actions = [
      Entry(title: "Update Project…", detail: "⌘T", symbol: "arrow.down.left",
        action: { [weak owner] in owner?.remoteAction("pull") }, enabled: owner.snapshot?.remotes.isEmpty == false),
      Entry(title: "Commit…", detail: "⌘K", symbol: "slider.horizontal.3",
        action: { [weak owner] in owner?.setMode("Commit") }),
      Entry(title: "Push…", detail: "⇧⌘K", symbol: "arrow.up.right",
        action: { [weak owner] in owner?.push() }, enabled: owner.snapshot?.remotes.isEmpty == false),
      Entry(title: "", separator: true),
      Entry(title: "New Branch…", detail: "⌥⌘N", symbol: "plus",
        action: { [weak owner] in owner?.newBranch() }),
      Entry(title: "Checkout Tag or Revision…", action: { [weak owner] in owner?.checkoutRevision() }),
    ]
    panel.delegate = self
    panel.isReleasedWhenClosed = false
    panel.hasShadow = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.minSize = NSSize(width: 375, height: 300)
    panel.setAccessibilityLabel("Branches and actions")
    let content = Surface(Theme.chrome)
    content.wantsLayer = true
    content.layer?.cornerRadius = 8
    content.layer?.borderWidth = 1
    content.layer?.borderColor = Theme.border.cgColor
    panel.contentView = content
    search.placeholderString = "Search for branches and actions"
    search.delegate = self
    search.sendsSearchStringImmediately = true
    search.setAccessibilityLabel("Search for branches and actions")
    let restore = ActionButton(symbol: "arrow.down.right.and.arrow.up.left", tooltip: "Restore default size", size: 28) { [weak self] in
      self?.restoreSize()
    }
    let settings = ActionButton(symbol: "gearshape", tooltip: "Branch popup settings", size: 28) { [weak self] in
      self?.showSettings()
    }
    let header = row([search, restore, settings], spacing: 10)
    header.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(header)
    let column = NSTableColumn(identifier: .init("branchPicker"))
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 26
    table.intercellSpacing = .zero
    table.backgroundColor = Theme.chrome
    table.selectionHighlightStyle = .regular
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(activateSelection)
    table.handleKey = { [weak self] event in self?.handleKey(event) ?? false }
    table.setAccessibilityLabel("Git branches and actions")
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = table
    scroll.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(scroll)
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
      header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
      scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
      scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
      scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
      scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
    ])
    rebuild()
  }

  func show(anchor: NSView) {
    guard let window = anchor.window else { return }
    if panel.isVisible { close(); return }
    let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    let screen = window.screen?.visibleFrame ?? rect.insetBy(dx: -500, dy: -500)
    let width = min(440, screen.width)
    let height = min(520, screen.height)
    panel.setFrame(NSRect(x: min(max(screen.minX, rect.minX), screen.maxX - width),
      y: max(screen.minY, rect.minY - height - 4), width: width, height: height), display: false)
    window.addChildWindow(panel, ordered: .above)
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(search)
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
      guard let self, !self.trackingMenu else { return event }
      if event.type == .keyDown, event.window === self.panel {
        if self.handleShortcut(event) { return nil }
        if self.panel.firstResponder === self.table, event.keyCode != 49,
          event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
          let characters = event.characters, !characters.isEmpty,
          characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
          self.panel.makeFirstResponder(self.search)
          self.search.currentEditor()?.keyDown(with: event)
          return nil
        }
      }
      if event.type != .keyDown, event.window !== self.panel { self.close() }
      return event
    }
  }

  func close() {
    if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    let parent = panel.parent
    parent?.removeChildWindow(panel)
    panel.orderOut(nil)
    if panel.isKeyWindow { parent?.makeKey() }
  }
  func windowDidResignKey(_ notification: Notification) {
    if !trackingMenu { close() }
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
  deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

  func rebuild() {
    guard let owner else { return }
    let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let selected = query == lastQuery && entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
    lastQuery = query
    entries = actions.filter { !($0.separator && !query.isEmpty) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
    let roots = BranchTree.build(owner.snapshot?.branches ?? [], favorites: owner.favoriteRefs,
      search: query, grouped: grouped, showTags: showTags).dropFirst()
    if !entries.isEmpty && !roots.isEmpty { entries.append(Entry(title: "", separator: true)) }
    func append(_ node: BranchNode, depth: Int, parent: String) {
      let path = parent + "/" + node.title
      let expanded = !collapsed.contains(path) || !query.isEmpty
      entries.append(Entry(title: node.title, detail: node.branch?.upstream ?? "", branch: node.branch,
        path: node.branch == nil ? path : nil, depth: depth, expanded: expanded))
      if node.branch == nil && expanded {
        for child in node.children { append(child, depth: depth + 1, parent: path) }
      }
    }
    for root in roots { append(root, depth: 0, parent: "") }
    if entries.isEmpty { entries = [Entry(title: "No branches or actions found", enabled: false)] }
    table.reloadData()
    let preferred = entries.firstIndex { entry in
      if let branch = selected?.branch { return entry.branch?.fullRef == branch.fullRef }
      if let path = selected?.path { return entry.path == path }
      return false
    } ?? entries.firstIndex { $0.branch?.current == true }
      ?? entries.firstIndex { $0.enabled && ($0.branch != nil || $0.action != nil) }
      ?? entries.firstIndex { !$0.separator && $0.enabled }
    if let preferred {
      table.selectRowIndexes(IndexSet(integer: preferred), byExtendingSelection: false)
      table.scrollRowToVisible(preferred)
    } else { table.deselectAll(nil) }
  }
  func controlTextDidChange(_ obj: Notification) { rebuild() }
  func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { entries[row].separator ? 18 : 26 }
  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !entries[row].separator && entries[row].enabled }
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let view = SelectionRow()
    view.usesInactiveColor = false
    return view
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
    let entry = entries[index]
    let cell = NSView()
    if entry.separator {
      let line = Surface(Theme.line)
      line.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(line)
      NSLayoutConstraint.activate([line.heightAnchor.constraint(equalToConstant: 1),
        line.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        line.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
        line.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8)])
      return cell
    }
    let icon = NSImageView()
    var symbol = entry.symbol
    var tint = Theme.text
    if let branch = entry.branch {
      switch BranchTree.icon(for: branch, favorites: owner?.favoriteRefs ?? []) {
      case .current: symbol = "tag.fill"; tint = Theme.yellow
      case .favorite: symbol = "star.fill"; tint = Theme.yellow
      case .tag: symbol = "tag"
      case .branch: icon.image = Theme.branchIcon
      }
    } else if entry.path != nil { symbol = entry.expanded ? "chevron.down" : "chevron.right" }
    if let symbol { icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    icon.contentTintColor = entry.enabled ? tint : Theme.muted
    let title = label(entry.title, color: entry.enabled ? Theme.text : Theme.muted)
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let detail = label(entry.detail, color: entry.action != nil ? Theme.muted : Theme.text)
    detail.lineBreakMode = .byTruncatingMiddle
    detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let arrow = NSImageView()
    if entry.branch != nil { arrow.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Branch actions") }
    arrow.contentTintColor = Theme.muted
    var contents: [NSView] = [icon]
    if entry.path != nil && entry.depth > 0 {
      let folder = NSImageView()
      folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
      folder.contentTintColor = Theme.text
      folder.widthAnchor.constraint(equalToConstant: 16).isActive = true
      folder.heightAnchor.constraint(equalToConstant: 16).isActive = true
      contents.append(folder)
    }
    contents += [title, NSView(), detail, arrow]
    let stack = row(contents, spacing: 8)
    stack.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(stack)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
      arrow.widthAnchor.constraint(equalToConstant: 10), arrow.heightAnchor.constraint(equalToConstant: 14),
      detail.widthAnchor.constraint(lessThanOrEqualToConstant: 170),
      stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12 + CGFloat(entry.depth) * 20),
      stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
      stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    cell.toolTip = entry.branch.map { $0.name + ($0.upstream.isEmpty ? "" : " → " + $0.upstream + " " + $0.tracking) }
    return cell
  }

  @objc private func activateSelection() {
    guard entries.indices.contains(table.selectedRow) else { return }
    let entry = entries[table.selectedRow]
    guard entry.enabled else { return }
    if let path = entry.path {
      if !collapsed.insert(path).inserted { collapsed.remove(path) }
      rebuild()
    } else if let branch = entry.branch, let owner {
      let menu = owner.branchMenu(branch)
      let rect = table.rect(ofRow: table.selectedRow)
      var invoked = false
      let observer = NotificationCenter.default.addObserver(forName: NSMenu.willSendActionNotification,
        object: menu, queue: .main) { _ in invoked = true }
      trackingMenu = true
      menu.popUp(positioning: nil, at: NSPoint(x: table.bounds.maxX - 4, y: rect.minY), in: table)
      trackingMenu = false
      NotificationCenter.default.removeObserver(observer)
      if invoked { close() } else { panel.makeKey(); panel.makeFirstResponder(search) }
    } else if let action = entry.action { close(); action() }
  }
  private func moveSelection(_ delta: Int) {
    var index = table.selectedRow
    repeat { index += delta } while entries.indices.contains(index) && (entries[index].separator || !entries[index].enabled)
    guard entries.indices.contains(index) else { return }
    table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    table.scrollRowToVisible(index)
  }
  private func handleShortcut(_ event: NSEvent) -> Bool {
    if event.keyCode == 53 { close(); return true }
    let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
    let key = event.charactersIgnoringModifiers?.lowercased()
    let index: Int?
    if modifiers == .command && key == "t" { index = 0 }
    else if modifiers == .command && key == "k" { index = 1 }
    else if modifiers == [.command, .shift] && key == "k" { index = 2 }
    else if modifiers == [.command, .option] && key == "n" { index = 4 }
    else { index = nil }
    if let index {
      if actions[index].enabled { close(); actions[index].action?() }
      return true
    }
    return false
  }
  private func handleKey(_ event: NSEvent) -> Bool {
    if handleShortcut(event) { return true }
    switch event.keyCode {
    case 125: moveSelection(1)
    case 126: moveSelection(-1)
    case 36, 76: activateSelection()
    case 124:
      if entries.indices.contains(table.selectedRow), let path = entries[table.selectedRow].path {
        collapsed.remove(path); rebuild()
      } else { activateSelection() }
    case 123:
      guard entries.indices.contains(table.selectedRow) else { return true }
      if let path = entries[table.selectedRow].path { collapsed.insert(path); rebuild() }
      else {
        let depth = entries[table.selectedRow].depth
        if let parent = entries[..<table.selectedRow].lastIndex(where: { $0.path != nil && $0.depth < depth }) {
          table.selectRowIndexes(IndexSet(integer: parent), byExtendingSelection: false)
          table.scrollRowToVisible(parent)
        }
      }
    case 49:
      guard !event.isARepeat, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
      guard entries.indices.contains(table.selectedRow), let branch = entries[table.selectedRow].branch else { return false }
      owner?.toggleFavorite(branch); rebuild()
    default: return false
    }
    return true
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.moveDown(_:)): moveSelection(1)
    case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
    case #selector(NSResponder.insertNewline(_:)): activateSelection()
    case #selector(NSResponder.cancelOperation(_:)): close()
    default: return false
    }
    return true
  }
  private func restoreSize() {
    var frame = panel.frame
    frame.origin.y += frame.height - 520
    frame.size = NSSize(width: 440, height: 520)
    if let screen = panel.screen?.visibleFrame {
      frame.size.width = min(frame.width, screen.width)
      frame.size.height = min(frame.height, screen.height)
      frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
      frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
    }
    panel.setFrame(frame, display: true)
  }
  private func showSettings() {
    let menu = NSMenu()
    let group = menuItem("Group by Directory") { [weak self] in
      guard let self else { return }
      grouped.toggle(); UserDefaults.standard.set(grouped, forKey: "branchPickerGroupDirectories"); rebuild()
    }
    group.state = grouped ? .on : .off
    menu.addItem(group)
    let tags = menuItem("Show Tags") { [weak self] in
      guard let self else { return }
      showTags.toggle(); UserDefaults.standard.set(showTags, forKey: "branchPickerShowTags"); rebuild()
    }
    tags.state = showTags ? .on : .off
    menu.addItem(tags)
    trackingMenu = true
    menu.popUp(positioning: nil, at: NSPoint(x: panel.contentView!.bounds.maxX - 20,
      y: panel.contentView!.bounds.maxY - 50), in: panel.contentView)
    trackingMenu = false
    panel.makeKey()
  }
}

private final class BranchPickerPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
final class BranchPickerTable: NSTableView {
  var handleKey: ((NSEvent) -> Bool)?
  private var hoverArea: NSTrackingArea?
  private var hoveredRow = -1
  override func reloadData() {
    setHoveredRow(-1)
    super.reloadData()
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    hoverArea = area
    addTrackingArea(area)
  }
  override func mouseMoved(with event: NSEvent) {
    setHoveredRow(row(at: convert(event.locationInWindow, from: nil)))
  }
  override func mouseExited(with event: NSEvent) { setHoveredRow(-1) }
  private func setHoveredRow(_ row: Int) {
    if hoveredRow >= 0 && hoveredRow < numberOfRows { (rowView(atRow: hoveredRow, makeIfNecessary: false) as? SelectionRow)?.isHovered = false }
    hoveredRow = row
    if row >= 0 && row < numberOfRows, delegate?.tableView?(self, shouldSelectRow: row) != false {
      (rowView(atRow: row, makeIfNecessary: false) as? SelectionRow)?.isHovered = true
    }
  }
  override func keyDown(with event: NSEvent) {
    if handleKey?(event) != true { super.keyDown(with: event) }
  }
}
