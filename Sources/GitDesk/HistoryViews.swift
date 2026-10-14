import AppKit
import GitDeskCore

func historyMessagePrompt(_ title: String, message: String) -> String? {
  let alert = NSAlert()
  alert.messageText = title
  alert.informativeText = "Edit the subject and optional body. File contents and unrelated staged changes are preserved."
  alert.addButton(withTitle: "Save Message")
  alert.addButton(withTitle: "Cancel")
  let text = NSTextView()
  text.isRichText = false
  text.font = Theme.font
  text.textColor = Theme.text
  text.backgroundColor = Theme.background
  text.textContainerInset = NSSize(width: 10, height: 10)
  text.allowsUndo = true
  text.string = message
  text.setAccessibilityLabel("New commit message")
  let scroll = scrollView(text)
  scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
  scroll.hasHorizontalScroller = false
  alert.accessoryView = scroll
  alert.window.initialFirstResponder = text
  return alert.runModal() == .alertFirstButtonReturn ? text.string : nil
}

final class RebaseEditor: NSView, ThemeUpdating, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
  func refreshTheme() { layer?.backgroundColor = Theme.background.cgColor }
  var entries: [RebaseEntry]
  let table = NSTableView()
  let message = PlaceholderTextView()
  let messageTitle = label("Message", bold: true)
  private var changingSelection = false
  init(entries: [RebaseEntry]) {
    self.entries = entries
    super.init(frame: NSRect(x: 0, y: 0, width: 720, height: 410))
    wantsLayer = true
    layer?.backgroundColor = Theme.background.cgColor
    let hint = label("Oldest first · Squash/Fixup joins the preceding retained row", color: Theme.muted, size: 12)
    hint.frame = NSRect(x: 0, y: 385, width: 720, height: 25)
    addSubview(hint)
    configureTable(table)
    table.rowHeight = 30
    table.delegate = self
    table.dataSource = self
    table.setAccessibilityLabel("Interactive rebase plan")
    for (id, title, width) in [("action", "Action", 100.0), ("hash", "Commit", 90.0), ("subject", "Message", 510.0)] {
      let column = NSTableColumn(identifier: .init(id))
      column.title = title
      column.width = width
      table.addTableColumn(column)
    }
    let list = scrollView(table)
    list.frame = NSRect(x: 0, y: 195, width: 720, height: 185)
    list.hasHorizontalScroller = false
    addSubview(list)
    let controls = row([
      ActionButton("Move Up", symbol: "arrow.up") { [weak self] in self?.move(-1) },
      ActionButton("Move Down", symbol: "arrow.down") { [weak self] in self?.move(1) },
      ActionButton("Use Automatic Message") { [weak self] in
        guard let self, self.table.selectedRow >= 0 else { return }
        self.entries[self.table.selectedRow].message = nil
        self.showMessage()
      }, NSView(),
    ])
    controls.frame = NSRect(x: 0, y: 157, width: 720, height: 30)
    addSubview(controls)
    messageTitle.frame = NSRect(x: 0, y: 130, width: 720, height: 23)
    addSubview(messageTitle)
    message.isRichText = false
    message.font = Theme.font
    message.textColor = Theme.text
    message.backgroundColor = Theme.background
    message.textContainerInset = NSSize(width: 8, height: 8)
    message.allowsUndo = true
    message.delegate = self
    message.setAccessibilityLabel("Rebase commit message")
    let editor = scrollView(message)
    editor.frame = NSRect(x: 0, y: 24, width: 720, height: 102)
    editor.hasHorizontalScroller = false
    addSubview(editor)
    let footer = label("Reword changes the message · Drop removes a commit · Fixup keeps the earlier message", color: Theme.muted, size: 11)
    footer.frame = NSRect(x: 0, y: 0, width: 720, height: 20)
    addSubview(footer)
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    showMessage()
  }
  required init?(coder: NSCoder) { fatalError() }
  func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let entry = entries[row]
    if tableColumn?.identifier.rawValue == "action" {
      let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 96, height: 26))
      popup.addItems(withTitles: RebaseAction.allCases.map { $0.rawValue.capitalized })
      popup.selectItem(at: RebaseAction.allCases.firstIndex(of: entry.action) ?? 0)
      popup.tag = row
      popup.target = self
      popup.action = #selector(actionChanged(_:))
      popup.setAccessibilityLabel("Action for " + entry.commit.shortHash)
      return popup
    }
    let text = label(tableColumn?.identifier.rawValue == "hash" ? entry.commit.shortHash : entry.commit.subject,
      color: entry.action == .drop ? Theme.muted : Theme.text)
    text.toolTip = entry.commit.fullMessage
    let cell = NSTableCellView()
    cell.textField = text
    let stack = NSStackView(views: [text])
    stack.alignment = .centerY
    pin(stack, to: cell, inset: 3)
    return cell
  }
  @objc func actionChanged(_ sender: NSPopUpButton) {
    entries[sender.tag].action = RebaseAction.allCases[sender.indexOfSelectedItem]
    table.reloadData(forRowIndexes: IndexSet(integer: sender.tag), columnIndexes: IndexSet(integersIn: 1...2))
    table.selectRowIndexes(IndexSet(integer: sender.tag), byExtendingSelection: false)
    showMessage()
  }
  func tableViewSelectionDidChange(_ notification: Notification) { showMessage() }
  func showMessage() {
    let index = table.selectedRow
    guard entries.indices.contains(index) else { return }
    changingSelection = true
    let entry = entries[index]
    message.isEditable = entry.action == .reword || entry.action == .squash
    message.string = entry.action == .squash ? entry.message ?? "" : entry.message ?? entry.commit.fullMessage
    message.placeholder = entry.action == .squash ? "Automatic: combine the earlier and this commit's messages" : "Commit message"
    message.needsDisplay = true
    messageTitle.stringValue = "\(entry.action.rawValue.capitalized): \(entry.commit.shortHash)"
      + (message.isEditable ? " — editable message" : " — message preview")
    changingSelection = false
  }
  func textDidChange(_ notification: Notification) {
    guard !changingSelection, message.isEditable, entries.indices.contains(table.selectedRow) else { return }
    let index = table.selectedRow
    entries[index].message = entries[index].action == .squash && message.string.isEmpty ? nil : message.string
  }
  func move(_ offset: Int) {
    let index = table.selectedRow
    let target = index + offset
    guard entries.indices.contains(index), entries.indices.contains(target) else { return }
    entries.swapAt(index, target)
    table.reloadData()
    table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
    table.scrollRowToVisible(target)
    showMessage()
  }
  static func present(_ entries: [RebaseEntry], plan: RebasePlan, published: [String]) -> [RebaseEntry]? {
    let editor = RebaseEditor(entries: entries)
    let alert = NSAlert()
    alert.messageText = "Interactive Rebase"
    alert.informativeText = "Edit the current branch's history from the selected commit through HEAD. Conflicts can be resolved, continued, skipped, or aborted."
      + (published.isEmpty ? "" : "\nPublished history: " + published.joined(separator: ", ") + ". Rewritten commits will require a force push outside GitDesk.")
    alert.accessoryView = editor
    alert.addButton(withTitle: "Start Rebase")
    alert.addButton(withTitle: "Cancel")
    while alert.runModal() == .alertFirstButtonReturn {
      do {
        try GitRepository.validateRebaseEntries(editor.entries, plan: plan)
        return editor.entries
      } catch {
        let warning = NSAlert()
        warning.messageText = "Check Rebase Plan"
        warning.informativeText = error.localizedDescription
        warning.runModal()
      }
    }
    return nil
  }
}

private final class RevisionNode {
  let title: String
  var file: RevisionFile?
  var children: [RevisionNode] = []
  init(_ title: String) { self.title = title }
}
final class RevisionBrowserWindowController: NSWindowController, NSWindowDelegate,
  NSOutlineViewDataSource, NSOutlineViewDelegate
{
  let repository: GitRepository
  let revision: Commit
  let outline = NSOutlineView()
  let text = NSTextView()
  let heading = label("Loading repository snapshot…", color: Theme.muted)
  private var nodes: [RevisionNode] = []
  private let queue = DispatchQueue(label: "gitdesk.revision", qos: .userInitiated)
  private var token = 0
  var onClose: (() -> Void)?
  init(repository: GitRepository, revision: Commit) {
    self.repository = repository
    self.revision = revision
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 650),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "Repository at \(revision.shortHash) — \(repository.workingDirectory.lastPathComponent)"
    window.minSize = NSSize(width: 720, height: 450)
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    let content = Surface()
    window.contentView = content
    let split = GitSplitView()
    split.isVertical = true
    split.dividerStyle = .thin
    configureTable(outline)
    let column = NSTableColumn(identifier: .init("file"))
    column.width = 280
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    outline.delegate = self
    outline.dataSource = self
    outline.setAccessibilityLabel("Historical repository files")
    split.addArrangedSubview(scrollView(outline))
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    text.textColor = Theme.text
    text.backgroundColor = Theme.background
    text.textContainerInset = NSSize(width: 14, height: 12)
    text.setAccessibilityLabel("Historical file contents (read only)")
    split.addArrangedSubview(scrollView(text))
    heading.translatesAutoresizingMaskIntoConstraints = false
    split.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(heading)
    content.addSubview(split)
    NSLayoutConstraint.activate([
      heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
      heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
      heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 9),
      heading.heightAnchor.constraint(equalToConstant: 24),
      split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      split.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
      split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
    content.layoutSubtreeIfNeeded()
    split.setPosition(300, ofDividerAt: 0)
    queue.async { [weak self] in
      do {
        let files = try repository.revisionFiles(at: revision.hash)
        var roots: [RevisionNode] = []
        var folders: [String: RevisionNode] = [:]
        for file in files {
          let parts = file.path.split(separator: "/").map(String.init)
          var parent: RevisionNode?
          var path = ""
          for (index, part) in parts.enumerated() {
            path += "/" + part
            if index == parts.count - 1 {
              let leaf = RevisionNode(part)
              leaf.file = file
              if let parent { parent.children.append(leaf) } else { roots.append(leaf) }
            } else if let existing = folders[path] {
              parent = existing
            } else {
              let folder = RevisionNode(part)
              folders[path] = folder
              if let parent { parent.children.append(folder) } else { roots.append(folder) }
              parent = folder
            }
          }
        }
        func sorted(_ values: [RevisionNode]) -> [RevisionNode] {
          for value in values { value.children = sorted(value.children) }
          return values.sorted {
            if ($0.file == nil) != ($1.file == nil) { return $0.file == nil }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
          }
        }
        let result = sorted(roots)
        DispatchQueue.main.async {
          guard let self else { return }
          self.nodes = result
          self.outline.reloadData()
          self.heading.stringValue = "\(revision.shortHash) · \(revision.subject) · \(files.count) files · Read only"
          if self.outline.numberOfRows > 0 { self.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        }
      } catch {
        DispatchQueue.main.async { self?.heading.stringValue = error.localizedDescription }
      }
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  func windowWillClose(_ notification: Notification) { token += 1; onClose?() }
  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    (item as? RevisionNode)?.children.count ?? nodes.count
  }
  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    ((item as? RevisionNode)?.children ?? nodes)[index]
  }
  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    !(item as! RevisionNode).children.isEmpty
  }
  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    let node = item as! RevisionNode
    let cell = NSTableCellView()
    let icon: NSImageView = node.file.map { FileTypeImageView(path: $0.path) }
      ?? NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")!)
    if node.file == nil { icon.contentTintColor = Theme.muted }
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
    let title = label(node.title)
    cell.textField = title
    pin(row([icon, title]), to: cell, inset: 3)
    return cell
  }
  func outlineViewSelectionDidChange(_ notification: Notification) {
    token += 1
    let current = token
    guard let file = (outline.item(atRow: outline.selectedRow) as? RevisionNode)?.file else {
      text.string = "Select a file to view its contents at \(revision.shortHash)."
      return
    }
    text.string = "Loading…"
    heading.stringValue = "\(revision.shortHash) · \(file.path) · Read only"
    queue.async { [weak self] in
      guard let self else { return }
      let result: String
      do {
        let data = try self.repository.revisionContents(file)
        result = data.contains(0) ? "Binary file · \(data.count) bytes" : String(data: data, encoding: .utf8) ?? "This file is not UTF-8 text."
      } catch { result = error.localizedDescription }
      DispatchQueue.main.async {
        guard self.token == current else { return }
        self.text.string = result
        self.text.scrollRangeToVisible(NSRange(location: 0, length: 0))
      }
    }
  }
}
