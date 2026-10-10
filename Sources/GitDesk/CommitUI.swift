import AppKit
import GitDeskCore

final class CommitChangesTable: MenuTable {
  var toggleSelection: (() -> Void)?
  var changeExpansion: ((Bool) -> Bool)?
  override func keyDown(with event: NSEvent) {
    if event.charactersIgnoringModifiers == " ",
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
      toggleSelection?()
      return
    }
    if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .control,
      event.charactersIgnoringModifiers == "p" || event.charactersIgnoringModifiers == "m" {
      toggleGrouping?(event.charactersIgnoringModifiers == "p")
      return
    }
    if event.keyCode == 123 || event.keyCode == 124,
      changeExpansion?(event.keyCode == 124) == true { return }
    super.keyDown(with: event)
  }
  var toggleGrouping: ((Bool) -> Void)?
}

final class CommitCheckbox: NSButton {
  init(target: AnyObject?, action: Selector?) {
    super.init(frame: .zero)
    setButtonType(.switch)
    title = ""
    self.target = target
    self.action = action
    allowsMixedState = true
    translatesAutoresizingMaskIntoConstraints = false
    widthAnchor.constraint(equalToConstant: 18).isActive = true
    heightAnchor.constraint(equalToConstant: 18).isActive = true
  }
  required init?(coder: NSCoder) { fatalError() }
  override func draw(_ dirtyRect: NSRect) {
    let symbol = state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square"
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
    let rect = NSRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
    if let image {
      // Tint a system symbol while retaining the native checkbox's state and accessibility.
      NSGraphicsContext.saveGraphicsState()
      let tinted = NSImage(size: rect.size)
      tinted.lockFocus()
      image.draw(in: NSRect(origin: .zero, size: rect.size))
      (state == .off ? Theme.muted : Theme.accent).setFill()
      NSRect(origin: .zero, size: rect.size).fill(using: .sourceAtop)
      tinted.unlockFocus()
      tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.4,
        respectFlipped: true, hints: nil)
      NSGraphicsContext.restoreGraphicsState()
    }
  }
}

extension RepositoryController {
  func buildCommit() {
    configureTable(changesTable)
    changesTable.rowHeight = 24
    changesTable.dataSource = self
    changesTable.delegate = self
    changesTable.allowsMultipleSelection = true
    changesTable.setAccessibilityLabel("Local Changes")
    let column = NSTableColumn(identifier: .init("path"))
    column.width = 380
    changesTable.addTableColumn(column)
    changesTable.target = self
    changesTable.doubleAction = #selector(showWorkingDiff)
    changesTable.menuProvider = { [weak self] in self?.fileContextMenu(working: true) ?? NSMenu() }
    changesTable.toggleSelection = { [weak self] in self?.toggleWorkingSelection() }
    changesTable.changeExpansion = { [weak self] expanded in self?.expandWorkingSelection(expanded) ?? false }
    changesTable.toggleGrouping = { [weak self] directory in
      guard let self else { return }
      if directory { self.groupCommitDirectories.toggle() } else { self.groupCommitModules.toggle() }
      self.rebuildWorkingRows()
    }
    commitRollbackButton = ActionButton(symbol: "arrow.uturn.backward", tooltip: "Rollback…", size: 24) {
      [weak self] in self?.rollback()
    }
    commitDiffButton = ActionButton(symbol: "arrow.left.arrow.right", tooltip: "Show Diff", size: 24) {
      [weak self] in self?.showWorkingDiff()
    }
    let viewOptions = ActionButton(symbol: "eye", tooltip: "View Options", size: 24) {}
    viewOptions.handler = { [weak self, weak viewOptions] in self?.commitViewOptions(anchor: viewOptions) }
    let toolbar = row([
      ActionButton(symbol: "arrow.clockwise", tooltip: "Refresh", size: 24) { [weak self] in self?.refresh() },
      commitRollbackButton, commitDiffButton,
      ActionButton(symbol: "archivebox", tooltip: "Stash Changes…", size: 24) { [weak self] in self?.stashChanges() },
      viewOptions,
      Surface(Theme.line),
      ActionButton(symbol: "arrow.up.left.and.arrow.down.right", tooltip: "Expand All", size: 24) { [weak self] in
        self?.collapsedChanges.removeAll()
        self?.rebuildWorkingRows()
      },
      ActionButton(symbol: "arrow.down.right.and.arrow.up.left", tooltip: "Collapse All", size: 24) { [weak self] in
        guard let self else { return }
        self.collapsedChanges.formUnion(self.workingRows.filter(\.isGroup).map(\.id))
        self.rebuildWorkingRows()
      }, NSView(),
    ], spacing: 2)
    let divider = toolbar.arrangedSubviews[5]
    divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
    divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
    let treeScroll = scrollView(changesTable)
    treeScroll.hasHorizontalScroller = false
    let treeArea = Surface()
    for child in [toolbar, treeScroll] {
      child.translatesAutoresizingMaskIntoConstraints = false
      treeArea.addSubview(child)
    }
    NSLayoutConstraint.activate([
      toolbar.leadingAnchor.constraint(equalTo: treeArea.leadingAnchor, constant: 10),
      toolbar.trailingAnchor.constraint(equalTo: treeArea.trailingAnchor, constant: -10),
      toolbar.topAnchor.constraint(equalTo: treeArea.topAnchor, constant: 2),
      toolbar.heightAnchor.constraint(equalToConstant: 30),
      treeScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
      treeScroll.leadingAnchor.constraint(equalTo: treeArea.leadingAnchor, constant: 13),
      treeScroll.trailingAnchor.constraint(equalTo: treeArea.trailingAnchor, constant: -11),
      treeScroll.bottomAnchor.constraint(equalTo: treeArea.bottomAnchor),
    ])

    amend.title = ""
    amend.target = self
    amend.action = #selector(amendChanged)
    amend.allowsMixedState = false
    amend.setAccessibilityLabel("Amend last commit")
    styleCheckbox(amend)
    let lastCommit = ActionButton("last commit", symbol: "chevron.down", size: 24) { [weak self] in self?.showAmendCommitMenu() }
    lastCommit.imagePosition = .imageTrailing
    lastCommit.image = lastCommit.image?.withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
    lastCommit.contentTintColor = Theme.blue
    let amendRow = row([
      amend, ActionButton("Amend", size: 24) { [weak self] in
        guard let self else { return }
        self.amend.state = self.amend.state == .on ? .off : .on
        self.amendChanged()
      }, lastCommit,
      ActionButton(symbol: "clock", tooltip: "Commit Message History", size: 24) { [weak self] in self?.messageHistory() },
      NSView(),
    ], spacing: 4)
    commitMessage.isRichText = false
    commitMessage.isEditable = true
    commitMessage.isSelectable = true
    commitMessage.allowsUndo = true
    commitMessage.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    commitMessage.textColor = Theme.text
    commitMessage.backgroundColor = Theme.background
    commitMessage.insertionPointColor = Theme.blue
    commitMessage.textContainerInset = NSSize(width: 6, height: 5)
    commitMessage.setAccessibilityLabel("Commit Message")
    let messageScroll = scrollView(commitMessage)
    messageScroll.hasHorizontalScroller = false
    messageScroll.borderType = .noBorder
    let messageBox = Surface()
    messageBox.layer?.cornerRadius = 3
    messageBox.layer?.borderWidth = 1
    messageBox.borderColor = Theme.border
    messageBox.layer?.masksToBounds = true
    pin(messageScroll, to: messageBox, inset: 1)
    commitButton = ActionButton("Commit", size: 28) { [weak self] in self?.commitChanges(push: false) }
    commitButton.commitStyle = .primary
    let pushButton = ActionButton("Commit and Push…", size: 28) { [weak self] in self?.commitChanges(push: true) }
    pushButton.commitStyle = .secondary
    let buttons = row([
      commitButton, pushButton, NSView(),
      ActionButton(symbol: "gearshape", tooltip: "Commit Options", size: 24) { [weak self] in self?.showCommitOptions() },
    ], spacing: 6)
    let compose = Surface()
    for child in [amendRow, messageBox, buttons] {
      child.translatesAutoresizingMaskIntoConstraints = false
      compose.addSubview(child)
    }
    NSLayoutConstraint.activate([
      amendRow.topAnchor.constraint(equalTo: compose.topAnchor, constant: 3),
      amendRow.leadingAnchor.constraint(equalTo: compose.leadingAnchor, constant: 13),
      amendRow.trailingAnchor.constraint(equalTo: compose.trailingAnchor, constant: -11),
      amendRow.heightAnchor.constraint(equalToConstant: 30),
      messageBox.topAnchor.constraint(equalTo: amendRow.bottomAnchor, constant: 6),
      messageBox.leadingAnchor.constraint(equalTo: compose.leadingAnchor, constant: 13),
      messageBox.trailingAnchor.constraint(equalTo: compose.trailingAnchor, constant: -11),
      messageBox.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
      messageBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),
      buttons.leadingAnchor.constraint(equalTo: compose.leadingAnchor, constant: 13),
      buttons.trailingAnchor.constraint(equalTo: compose.trailingAnchor, constant: -11),
      buttons.bottomAnchor.constraint(equalTo: compose.bottomAnchor, constant: -9),
    ])
    commitSections = GitSplitView()
    commitSections.isVertical = false
    commitSections.dividerStyle = .thin
    commitSections.addArrangedSubview(treeArea)
    commitSections.addArrangedSubview(compose)
    treeArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
    compose.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    let hint = Surface()
    let text = label("Select a file to view its changes", color: Theme.muted)
    text.translatesAutoresizingMaskIntoConstraints = false
    hint.addSubview(text)
    NSLayoutConstraint.activate([
      text.centerXAnchor.constraint(equalTo: hint.centerXAnchor),
      text.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
    ])
    let workingSplit = GitSplitView()
    workingSplit.isVertical = true
    workingSplit.dividerStyle = .thin
    workingSplit.autosaveName = "CommitSplit"
    workingSplit.addArrangedSubview(commitSections)
    workingSplit.addArrangedSubview(hint)
    pin(workingSplit, to: commitBody)
  }

  func layoutCommitComposition() {
    guard mode == "Commit", !commitCompositionInitialized, let commitSections,
      commitSections.bounds.height > 300 else { return }
    commitSections.setPosition(commitSections.bounds.height - 205, ofDividerAt: 0)
    commitCompositionInitialized = true
  }

  func workingCell(at index: Int) -> NSView? {
    guard workingRows.indices.contains(index) else { return nil }
    let item = workingRows[index]
    let cell = NSTableCellView()
    var views: [NSView] = []
    let leading = NSView()
    leading.widthAnchor.constraint(equalToConstant: CGFloat(item.depth) * 18 + (item.isGroup ? 0 : 18)).isActive = true
    views.append(leading)
    if item.isGroup {
      if item.count > 0 {
        let arrow = ActionButton(symbol: collapsedChanges.contains(item.id) ? "chevron.right" : "chevron.down",
          tooltip: "Expand / Collapse " + item.title, size: 14) { [weak self] in self?.toggleWorkingGroup(item.id) }
        views.append(arrow)
        if !item.files.isEmpty { views.append(workingCheckbox(files: item.files, name: item.title, index: index)) }
      } else {
        let indent = NSView()
        indent.widthAnchor.constraint(equalToConstant: 16).isActive = true
        views.append(indent)
      }
      if item.kind == .module || item.kind == .directory {
        let icon = NSImageView(image: NSImage(systemSymbolName: item.kind == .module ? "shippingbox" : "folder",
          accessibilityDescription: item.kind == .module ? "Module" : "Directory") ?? NSImage())
        icon.contentTintColor = Theme.muted
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        views.append(icon)
      }
      views.append(label(item.title, bold: item.title == "Changes"))
      if item.count > 0 { views.append(label("\(item.count) " + (item.count == 1 ? "file" : "files"), color: Theme.muted, size: 12)) }
    } else if let file = item.file {
      views.append(workingCheckbox(files: [file], name: file.path + " in commit", index: index))
      let icon = NSImageView()
      let filename = (file.path as NSString).lastPathComponent
      let symbol = file.isConflicted ? "exclamationmark.triangle" : filename == ".gitignore" ? "nosign"
        : ["xml", "html", "swift", "java", "js", "ts", "json"].contains((filename as NSString).pathExtension)
          ? "chevron.left.forwardslash.chevron.right" : "doc"
      icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: file.status)
      let color = file.isConflicted || file.isUntracked ? Theme.red : file.status == "Added" ? Theme.green : Theme.blue
      icon.contentTintColor = file.isUntracked ? Theme.muted : color
      if symbol == "chevron.left.forwardslash.chevron.right" { icon.contentTintColor = Theme.keyword }
      icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
      icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
      views.append(icon)
      let name = label(item.title, color: color)
      name.toolTip = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
      name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
      views.append(name)
    } else if item.kind == .ignored {
      let icon = NSImageView(image: NSImage(systemSymbolName: item.path?.hasSuffix("/") == true ? "folder" : "doc",
        accessibilityDescription: "Ignored") ?? NSImage())
      icon.contentTintColor = Theme.muted
      icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
      views.append(icon)
      let name = label(item.title, color: Theme.muted)
      name.toolTip = item.path
      views.append(name)
    }
    views.append(NSView())
    let content = row(views, spacing: 4)
    pin(content, to: cell)
    return cell
  }
  private func workingCheckbox(files: [FileChange], name: String, index: Int) -> NSButton {
    let check = CommitCheckbox(target: self, action: #selector(checkFile(_:)))
    check.tag = index
    let included = files.filter { selectedPaths.contains($0.path) }.count
    check.state = included == 0 ? .off : included == files.count ? .on : .mixed
    check.setAccessibilityLabel("Include " + name)
    return check
  }
  func toggleWorkingGroup(_ name: String) {
    if collapsedChanges.contains(name) { collapsedChanges.remove(name) }
    else { collapsedChanges.insert(name) }
    rebuildWorkingRows()
  }
  func toggleWorkingSelection() {
    let files = changesTable.selectedRowIndexes.flatMap { workingRows.indices.contains($0) ? workingRows[$0].files : [] }
    guard !files.isEmpty else { return }
    let included = files.allSatisfy { selectedPaths.contains($0.path) }
    for file in files {
      if included { selectedPaths.remove(file.path) } else { selectedPaths.insert(file.path) }
    }
    reloadWorkingCells()
  }
  func reloadWorkingCells() {
    // Inclusion and display options change cells, not row identities or selection.
    changesTable.reloadData(forRowIndexes: IndexSet(integersIn: 0..<workingRows.count),
      columnIndexes: IndexSet(integer: 0))
  }
  func expandWorkingSelection(_ expanded: Bool) -> Bool {
    guard workingRows.indices.contains(changesTable.selectedRow),
      workingRows[changesTable.selectedRow].isGroup else { return false }
    let name = workingRows[changesTable.selectedRow].id
    if expanded { collapsedChanges.remove(name) } else { collapsedChanges.insert(name) }
    rebuildWorkingRows()
    if let index = workingRows.firstIndex(where: { $0.id == name }) {
      changesTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }
    return true
  }
  func updateCommitToolbar() {
    let files = workingSelection()
    commitRollbackButton?.isEnabled = !files.isEmpty && !isBusy
    commitDiffButton?.isEnabled = !files.isEmpty && !isBusy
  }
  func showAmendCommitMenu() {
    let menu = NSMenu()
    menu.addItem(menuItem("Amend Last Commit", enabled: snapshot?.branches.contains(where: \.current) == true) { [weak self] in
      self?.amend.state = .on
      self?.amendChanged()
    })
    menu.addItem(menuItem("Show Last Commit in Log") { [weak self] in
      guard let self, let head = self.snapshot?.branches.first(where: \.current)?.hash else { return }
      self.readHistory("Finding last commit", work: { try $0.commit(at: head) }) { self.revealHistoryCommit($0) }
    })
    popup(menu)
  }
  func commitViewOptions(anchor: NSView? = nil) {
    let menu = NSMenu()
    menu.addItem(NSMenuItem.sectionHeader(title: "Group By"))
    let directory = menuItem("Directory") { [weak self] in
      self?.groupCommitDirectories.toggle()
      self?.rebuildWorkingRows()
    }
    directory.state = groupCommitDirectories ? .on : .off
    directory.keyEquivalent = "p"
    directory.keyEquivalentModifierMask = .control
    menu.addItem(directory)
    let module = menuItem("Module") { [weak self] in
      self?.groupCommitModules.toggle()
      self?.rebuildWorkingRows()
    }
    module.state = groupCommitModules ? .on : .off
    module.keyEquivalent = "m"
    module.keyEquivalentModifierMask = .control
    menu.addItem(module)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem.sectionHeader(title: "Show"))
    let ignored = menuItem("Ignored Files") { [weak self] in
      guard let self else { return }
      self.showIgnoredFiles.toggle()
      if !self.showIgnoredFiles { self.ignoredPaths = [] }
      self.rebuildWorkingRows()
      self.refresh()
    }
    ignored.state = showIgnoredFiles ? .on : .off
    menu.addItem(ignored)
    popup(menu, anchor: anchor)
  }
  func showCommitOptions() {
    let signOff = NSButton(checkboxWithTitle: "Sign-off commit", target: nil, action: nil)
    signOff.state = commitSignOff ? .on : .off
    signOff.toolTip = "Append a Signed-off-by trailer using your Git committer identity."
    styleCheckbox(signOff)
    guard let values = prompt("Commit Options",
      fields: [("Author — Name <email> (empty uses Git default)", commitAuthor)], extra: signOff) else { return }
    commitAuthor = values[0].trimmingCharacters(in: .whitespacesAndNewlines)
    commitSignOff = signOff.state == .on
  }
}
