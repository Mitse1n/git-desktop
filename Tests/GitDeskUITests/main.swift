import AppKit
import GitDeskCore

defer {
  do { try runHistoryPaginationChecks(); try runFlowChecks(); try runHostingChecks() }
  catch { print(error.localizedDescription); exit(1) }
}

// Exercise the real console storage without opening a window or changing a repo.
let console = ConsoleTextView()
console.isHidden = true
precondition(console.textLayoutManager == nil)
let large = String(repeating: "history\0中文🙂\n", count: 100_000)
let preview = ConsoleTextView.preview(large)
precondition(preview.utf16.count <= ConsoleTextView.entryLimit + 40)
precondition(preview.contains("[Output truncated in Console]"))
precondition(!preview.contains("\0"))
let start = Date()
for _ in 0..<100 {
  console.appendEntry(large, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
  precondition(console.textStorage!.length <= ConsoleTextView.storageLimit)
  precondition(!console.string.contains("�"))
}
console.appendEntry("最新输出🙂\nExit code: 1\n", attributes: [:])
precondition(console.string.hasSuffix("最新输出🙂\nExit code: 1\n"))
console.string = large
console.appendEntry("git log\n" + preview + "\nExit code: 1\n", attributes: [:])
precondition(console.textStorage!.length <= ConsoleTextView.storageLimit)
precondition(console.string.hasSuffix("Exit code: 1\n"))
precondition(console.string.contains("[Output truncated in Console]"))
console.string = ""
precondition(console.textStorage!.length == 0)
print("Console oversized/Unicode/binary/repeated-output checks passed (\(String(format: "%.3f", Date().timeIntervalSince(start)))s)")

let expansionFont = NSFont.systemFont(ofSize: 13)
let sourceRect = NSRect(x: 240, y: 280, width: 60, height: 18)
let viewport = NSRect(x: 10, y: 20, width: 640, height: 320)
func expanded(_ text: String, bounds: NSRect = viewport, source: NSRect = sourceRect,
  flipped: Bool = false) -> LogTextExpansionLayout {
  let result = LogTextExpansionLayout.make(text: text, font: expansionFont,
    sourceRect: source, containerBounds: bounds, flipped: flipped)!
  precondition(bounds.contains(result.frame), "Expansion must remain inside the window")
  for line in result.lines {
    precondition((line as NSString).size(withAttributes: [.font: expansionFont]).width
      <= result.frame.width - LogTextExpansionLayout.padding.width * 2 + 0.5)
  }
  return result
}
precondition(!LogHoverText(text: "fix", font: expansionFont, color: .white, rect: sourceRect).isTruncated)
for text in ["A commit message that exceeds its column", "Author with a very long name", "2026/10/10 20:31"] {
  precondition(LogHoverText(text: text, font: expansionFont, color: .white, rect: sourceRect).isTruncated)
  let result = expanded(text)
  precondition(result.lines == [text] && result.frame.width > sourceRect.width)
}
let wrapped = expanded(String(repeating: "Readable words 中文 ", count: 15))
precondition(wrapped.lines.count > 1 && !wrapped.lines.last!.hasSuffix("..."))
for text in [String(repeating: "W", count: 100_000),
  String(repeating: "中文👩🏽‍💻e\u{301}", count: 10_000)] {
  for flipped in [false, true] {
    let result = expanded(text, source: NSRect(x: viewport.maxX - 40,
      y: viewport.minY + 1, width: 30, height: 18), flipped: flipped)
    precondition(result.lines.count > 1 && result.lines.last!.hasSuffix("..."))
    let prefix = result.lines.joined().dropLast(3)
    precondition(text.hasPrefix(String(prefix)), "Do not split Unicode graphemes")
  }
}
let small = expanded(String(repeating: "long message ", count: 100),
  bounds: NSRect(x: 0, y: 0, width: 150, height: 44))
precondition(small.lines.count == 2 && small.lines.last!.hasSuffix("..."))
precondition(LogTextExpansionLayout.make(text: "text", font: expansionFont,
  sourceRect: sourceRect, containerBounds: .zero, flipped: false) == nil)
print("Log text expansion: subject/author/date, wrapping, window edges, height truncation and Unicode checks passed")

// Exercise the actual table event handlers; keep this window off screen.
_ = NSApplication.shared
do {
  let commits = [
    Commit(hash: "main", parents: ["root"], author: "T", subject: "Main"),
    Commit(hash: "side-a", parents: ["root"], author: "T", subject: "Side A"),
    Commit(hash: "side-b", parents: ["root"], author: "T", subject: "Side B"),
    Commit(hash: "root", parents: [], author: "T", subject: "Root"),
  ]
  let rows = CommitGraph.layout(commits, heads: ["main", "side-a", "side-b"])
  let original = Theme.current
  defer { Theme.current = original }
  for theme in AppTheme.allCases {
    Theme.current = theme
    let cell = GraphCell(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
    cell.graph = rows[1]
    let bitmap = cell.bitmapImageRepForCachingDisplay(in: cell.bounds)!
    cell.cacheDisplay(in: cell.bounds, to: bitmap)
    func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor {
      bitmap.colorAt(x: Int(x * CGFloat(bitmap.pixelsWide) / 100),
        y: Int((40 - y) * CGFloat(bitmap.pixelsHigh) / 40))!.usingColorSpace(.sRGB)!
    }
    func matches(_ actual: NSColor, _ expected: NSColor) -> Bool {
      let expected = expected.usingColorSpace(.sRGB)!
      return actual.alphaComponent > 0.2 && abs(actual.redComponent - expected.redComponent) < 0.025
        && abs(actual.greenComponent - expected.greenComponent) < 0.025
        && abs(actual.blueComponent - expected.blueComponent) < 0.025
    }
    let branch = Theme.graph[rows[1].color % Theme.graph.count]
    precondition(matches(pixel(34, 20), branch), "The side-branch dot uses its branch color")
    precondition(matches(pixel(34, 10), branch), "The side-branch line matches its dot in " + theme.title)
    precondition(matches(pixel(16, 10), Theme.graph[rows[0].color % Theme.graph.count]),
      "A main connection passing through a side-branch row keeps its own color")
  }
  print("Graph rendering: branch dots/lines and passing main connections match in all four themes")
}
// Render a merge train through the real table/cell delegates, including
// graph overflow into the subject cell and the compact/long-edge switch.
do {
  let originalTheme = Theme.current
  defer { Theme.current = originalTheme }
  Theme.current = .dark
  var commits = (0..<8).map { Commit(hash: "m\($0)", parents: ["m\($0 + 1)", "side\($0)"],
    author: "Junio C Hamano", subject: "Merge branch 'topic-\($0)' into seen") }
  commits += [Commit(hash: "side0", parents: ["side0-old"], author: "Beat Bolli", subject: "imap-send: verify the hostname"),
    Commit(hash: "side0-old", parents: ["root"], author: "Beat Bolli", subject: "imap-send: use the recommended TLS method"),
    Commit(hash: "side1", parents: ["root"], author: "Beat Bolli", subject: "unicode: update the width tables")]
  for index in 8..<40 {
    commits.append(Commit(hash: "m\(index)", parents: [index == 39 ? "root" : "m\(index + 1)"],
      author: "Junio C Hamano", subject: "Main-line change \(index)"))
    if index < 12 {
      commits.append(Commit(hash: "side\(index - 6)", parents: ["root"], author: "Contributor", subject: "Topic change \(index - 6)"))
    }
  }
  for index in 6...7 {
    commits.append(Commit(hash: "side\(index)", parents: ["root"], author: "Contributor", subject: "Topic change \(index)"))
  }
  commits.append(Commit(hash: "root", parents: [], author: "Contributor", subject: "Root"))
  let controller = RepositoryController()
  _ = controller.view
  let savedPreference = controller.showLongGraphEdges
  defer { controller.showLongGraphEdges = savedPreference }
  controller.showLongGraphEdges = false
  let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1100, height: 520))
  scroll.documentView = controller.logTable
  let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = scroll
  defer { window.close() }
  controller.snapshot = RepositorySnapshot(branches: [], commits: commits, changes: [], currentBranch: "seen",
    remotes: [], stashes: [], operation: nil)
  controller.updateUI()
  controller.logTable.layoutSubtreeIfNeeded()
  let baseWidth = controller.logTable.graphWidth
  let wideRow = controller.graphs.indices.max { controller.graphs[$0].laneCount < controller.graphs[$1].laneCount }!
  let subject = controller.tableView(controller.logTable, viewFor: controller.logTable.tableColumns[1], row: wideRow) as! LogSubjectCell
  subject.frame = NSRect(x: 0, y: 0, width: 650, height: 26)
  precondition(subject.hoverText!.rect.minX >= GraphCell.requiredWidth(lanes: controller.graphs[wideRow].laneCount) - baseWidth,
    "Wide graph rows move only their own subject and hover hit area")
  controller.logTable.selectRowIndexes(IndexSet([2, 4]), byExtendingSelection: false)
  func render(_ name: String) throws {
    scroll.layoutSubtreeIfNeeded()
    let bitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds)!
    scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/" + name + ".png"))
  }
  try render("graph-compact")
  func drainGraph() {
    var done = false
    controller.queue.async { DispatchQueue.main.async { done = true } }
    let deadline = Date().addingTimeInterval(20)
    while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    precondition(done)
  }
  let origin = scroll.contentView.bounds.origin
  controller.toggleLongGraphEdges(); drainGraph()
  precondition(controller.historyPresentation!.showLongEdges)
  precondition(controller.logTable.selectedRowIndexes == IndexSet([2, 4]))
  precondition(scroll.contentView.bounds.origin == origin)
  try render("graph-long-edges")
  controller.toggleLongGraphEdges(); drainGraph()
  precondition(!controller.historyPresentation!.showLongEdges)
  precondition(controller.logTable.graphWidth == baseWidth)
  precondition(controller.logTable.selectedRowIndexes == IndexSet([2, 4]))
  print("Compact graph: per-row subject/hover geometry, real table rendering, async mode switch, selection and viewport passed")
} catch { print(error); exit(1) }
final class LogResizeDataSource: NSObject, NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int { 20 }
  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { nil }
}
let resizeDataSource = LogResizeDataSource()
let resizeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 240),
  styleMask: .borderless, backing: .buffered, defer: false)
let resizeScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
let resizeTable = LogTable(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
configureTable(resizeTable)
resizeTable.columnAutoresizingStyle = .noColumnAutoresizing
for (id, width, minimum) in [("graph", 44.0, 30.0), ("subject", 540, 100),
  ("author", 90, 70), ("date", 126, 70)] {
  let column = NSTableColumn(identifier: .init(id))
  column.minWidth = minimum
  column.width = width
  column.resizingMask = []
  resizeTable.addTableColumn(column)
}
resizeTable.dataSource = resizeDataSource
resizeScroll.documentView = resizeTable
resizeWindow.contentView = resizeScroll
resizeTable.reloadData()
resizeTable.fitColumns()
resizeTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
func columnWidths() -> [CGFloat] { resizeTable.tableColumns.map(\.width) }
func dragBoundary(_ column: Int, by delta: CGFloat) {
  let point = NSPoint(x: resizeTable.rect(ofColumn: column).maxX,
    y: resizeTable.visibleRect.minY + 14)
  precondition(resizeTable.hitTest(resizeTable.superview!.convert(point, from: resizeTable)) === resizeTable)
  let start = resizeTable.convert(point, to: nil)
  func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: start.y), modifierFlags: [],
      timestamp: 0, windowNumber: resizeWindow.windowNumber, context: nil,
      eventNumber: 0, clickCount: 1, pressure: 1)!
  }
  resizeTable.mouseDown(with: event(.leftMouseDown, x: start.x))
  resizeTable.mouseDragged(with: event(.leftMouseDragged, x: start.x + delta))
  resizeTable.mouseUp(with: event(.leftMouseUp, x: start.x + delta))
  precondition(resizeTable.selectedRowIndexes == IndexSet(integer: 1), "Resizing must not select a commit")
}
let originalWidths = columnWidths()
dragBoundary(1, by: -50)
precondition(columnWidths()[1] == originalWidths[1] - 50)
precondition(columnWidths()[2] == originalWidths[2] + 50)
precondition(columnWidths()[3] == originalWidths[3])
let beforeDateDrag = columnWidths()
dragBoundary(2, by: 30)
precondition(columnWidths()[1] == beforeDateDrag[1])
precondition(columnWidths()[2] == beforeDateDrag[2] + 30)
precondition(columnWidths()[3] == beforeDateDrag[3] - 30)
let manualWidths = columnWidths()
resizeTable.authorWidth = 80
resizeTable.reloadData()
resizeTable.fitColumns()
precondition(columnWidths() == manualWidths, "Refresh must preserve manual column widths")
resizeScroll.setFrameSize(NSSize(width: 680, height: 240))
resizeTable.fitColumns()
precondition(columnWidths()[2...3] == manualWidths[2...3])
precondition(abs(columnWidths().reduce(0, +) - resizeScroll.contentSize.width) < 0.5)
resizeScroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
dragBoundary(1, by: 10_000)
precondition(columnWidths()[2] == 70)
dragBoundary(1, by: -10_000)
precondition(columnWidths()[1] == 100)
dragBoundary(2, by: 10_000)
precondition(columnWidths()[3] == 70)
dragBoundary(2, by: -10_000)
precondition(columnWidths()[2] == 70)
precondition(resizeTable.tableColumns.allSatisfy { $0.width >= $0.minWidth })
print("Log column resizing: both dividers, selection, refresh, viewport resize, scrolling and minimum widths passed")

// Hover the real outline in an off-screen window with a neighboring log pane.
final class BranchHoverDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
  let names = ["platform-organization-governance", "main", String(repeating: "分支🙂", count: 100)]
  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    item == nil ? names.count : 0
  }
  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    NSNumber(value: index)
  }
  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    let name = names[(item as! NSNumber).intValue]
    let cell = BranchCell()
    let text = label(name)
    cell.textField = text
    cell.toolTip = "feat/\(name) → fork/feat/\(name)"
    pin(row([cell.branchIcon, text], spacing: 6), to: cell, inset: 3)
    cell.branchIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
    return cell
  }
}
do {
  let dataSource = BranchHoverDataSource()
  let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 240),
    styleMask: .borderless, backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  defer { window.close() }
  let content = window.contentView!
  let scroll = NSScrollView(frame: NSRect(x: 80, y: 0, width: 200, height: 240))
  let outline = BranchOutline(frame: scroll.bounds)
  let column = NSTableColumn(identifier: .init("branch"))
  column.minWidth = 1
  outline.addTableColumn(column)
  outline.outlineTableColumn = column
  configureTable(outline)
  outline.columnAutoresizingStyle = .noColumnAutoresizing
  outline.autoresizesOutlineColumn = false
  outline.rowHeight = 25
  outline.dataSource = dataSource
  outline.delegate = dataSource
  outline.contentWidthForItem = { item in
    let name = dataSource.names[(item as! NSNumber).intValue]
    return (name as NSString).size(withAttributes: [.font: Theme.font]).width + 32
  }
  scroll.documentView = outline
  content.addSubview(scroll)
  window.orderBack(nil)
  outline.reloadData()
  content.layoutSubtreeIfNeeded()
  outline.fitContentWidth()
  func hover(_ row: Int) {
    let rect = outline.rect(ofRow: row)
    let point = outline.convert(NSPoint(x: outline.visibleRect.minX + 60, y: rect.midY), to: nil)
    outline.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: point,
      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
      eventNumber: 0, clickCount: 0, pressure: 0)!)
  }
  for index in [0, 2] {
    hover(index)
    let expansion = outline.expansionView!
    let viewport = content.convert(outline.visibleRect, from: outline)
    precondition(expansion.frame.maxX <= viewport.maxX, "Branch expansion must never cover the log")
    precondition(expansion.frame.minX >= content.bounds.minX, "Expansion stays inside the window")
    precondition(expansion.hitTest(.zero) == nil, "Hover must pass clicks and scrolling through")
    let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: false) as! BranchCell
    precondition(cell.toolTip == "feat/\(dataSource.names[index]) → fork/feat/\(dataSource.names[index])",
      "The full branch/upstream tooltip must remain available during expansion")
    if index == 0 { precondition(expansion.textLayout.lines == [dataSource.names[index]]) }
    else { precondition(expansion.textLayout.lines.count > 1) }
  }
  hover(1)
  precondition(outline.expansionView == nil, "A fully visible name needs only its native tooltip")
  scroll.contentView.scroll(to: NSPoint(x: 100, y: 0))
  hover(0)
  precondition(outline.expansionView != nil, "Reveal names clipped by horizontal scrolling too")
  outline.mouseExited(with: NSEvent())
  precondition(outline.expansionView == nil && outline.hoveredRow == -1)
  print("Branch hover: pane boundary, full name, Unicode wrapping, tooltip, scrolling and exit passed")
}

// Match the screenshot: current local main, favorite origin/main, then dependabot folders.
do {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gitdesk-branch-tree-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repo = GitRepository(directory: directory)
  try repo.run(["init", "-b", "main"])
  try repo.run(["-c", "user.name=Test User", "-c", "user.email=test@example.test",
    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "Initial"])
  let remoteRefs = ["refs/remotes/origin/main",
    "refs/remotes/origin/dependabot/github_actions/actions/checkout-7.0.1",
    "refs/remotes/origin/dependabot/github_actions/actions/upload-artifact-7.0.2"]
  for ref in remoteRefs { try repo.run(["update-ref", ref, "HEAD"]) }
  try repo.run(["symbolic-ref", "refs/remotes/origin/HEAD", remoteRefs[0]])
  try repo.run(["tag", "main"])
  let suite = "dev.gitdesk.branch-tests." + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let favorites = BranchTree.favorites(in: defaults)
  precondition(favorites.contains("refs/heads/main") && favorites.contains(remoteRefs[0]))
  precondition(favorites.contains("refs/heads/master") && favorites.contains("refs/remotes/origin/master"))
  let branches = try repo.branches()
  let tree = BranchTree.build(branches, favorites: favorites)
  let local = tree.first { $0.title == "Local" }!
  let origin = tree.first { $0.title == "Remote" }!.children.first!
  precondition(local.children.map(\.title) == ["main"])
  precondition(BranchTree.icon(for: local.children[0].branch!, favorites: favorites) == .current)
  precondition(origin.title == "origin" && origin.children.map(\.title) == ["main", "dependabot"])
  precondition(origin.children[0].branch!.fullRef == remoteRefs[0])
  precondition(BranchTree.icon(for: origin.children[0].branch!, favorites: favorites) == .favorite)
  let actions = origin.children[1].children[0].children[0]
  precondition(actions.children.map { $0.branch!.fullRef } == Array(remoteRefs.dropFirst()))
  let tag = tree.first { $0.title == "Tags" }!.children.first!.branch!
  precondition(BranchTree.icon(for: tag, favorites: favorites) == .tag)
  let flat = BranchTree.build(branches, favorites: favorites, grouped: false)
  precondition(flat.first { $0.title == "Remote" }!.children.map { $0.branch!.fullRef } == remoteRefs)
  let onlyFavorites = BranchTree.build(branches, favorites: favorites, favoriteOnly: true)
  precondition(onlyFavorites.first { $0.title == "Remote" }!.children[0].children.map(\.title) == ["main"])
  precondition(!onlyFavorites.contains { $0.title == "Tags" })
  let searched = BranchTree.build(branches, favorites: favorites, search: "checkout")
  precondition(searched.count == 2 && searched[1].title == "Remote")
  defaults.set([String](), forKey: "favoriteRefs")
  precondition(BranchTree.favorites(in: defaults).isEmpty, "Respect explicitly removed default favorites")
  let noFavorites = BranchTree.build(branches, favorites: [], favoriteOnly: true)
  precondition(noFavorites.count == 2 && noFavorites[1].title == "Local")
  let unmarked = BranchTree.build(branches, favorites: [])
  precondition(unmarked.first { $0.title == "Remote" }!.children[0].children.map(\.title) == ["dependabot", "main"])
  defaults.set([remoteRefs[1]], forKey: "favoriteRefs")
  precondition(BranchTree.favorites(in: defaults) == [remoteRefs[1]], "Preserve custom favorites")
  try repo.run(["switch", "-c", "topic/work"])
  let switched = BranchTree.build(try repo.branches(), favorites: favorites)
  let firstLocal = switched.first { $0.title == "Local" }!.children[0]
  precondition(firstLocal.title == "topic" && firstLocal.children[0].branch!.current)
  precondition(BranchTree.icon(for: firstLocal.children[0].branch!, favorites: favorites) == .current)
  print("Branch tree: current marker, default remote favorites, grouped/flat order, filtering and custom favorites passed")
}

let commitFiles = [
  FileChange(path: "Sources/GitDesk/Theme.swift", worktree: "M"),
  FileChange(path: "Sources/GitDesk/CommitUI.swift", worktree: "M"),
  FileChange(path: "README.md", worktree: "M"),
  FileChange(path: "Notes/new.txt", index: "?", worktree: "?"),
  FileChange(path: "conflict.txt", index: "U", worktree: "U"),
]
func commitRows(directories: Bool = true, modules: Bool = false,
  collapsed: Set<String> = []) -> [WorkingRow] {
  CommitChanges.rows(changes: commitFiles, ignored: ["cache/", ".env"],
    modules: [CommitModule(name: "app", root: "Sources/GitDesk")],
    directories: directories, byModule: modules, collapsed: collapsed)
}
let directoryRows = commitRows()
let sourceFolder = directoryRows.first { $0.title == "Sources/GitDesk" }!
precondition(sourceFolder.isGroup && sourceFolder.files.count == 2 && sourceFolder.depth == 1)
precondition(directoryRows.first { $0.title == "Theme.swift" }!.depth == 2)
let collapsedRows = commitRows(collapsed: [sourceFolder.id])
precondition(!collapsedRows.contains { $0.file?.path == "Sources/GitDesk/Theme.swift" })
precondition(collapsedRows.first { $0.id == sourceFolder.id }!.files.count == 2)
let flatRows = commitRows(directories: false)
precondition(!flatRows.contains { $0.kind == .directory })
precondition(flatRows.first { $0.file?.path == "Sources/GitDesk/Theme.swift" }!.title == "Sources/GitDesk/Theme.swift")
precondition(Set(flatRows.filter { $0.file != nil }.map(\.id)) == Set(directoryRows.filter { $0.file != nil }.map(\.id)),
  "File selection identities must survive regrouping")
let moduleRows = commitRows(modules: true)
precondition(moduleRows.first { $0.kind == .module }!.title == "app")
precondition(moduleRows.first { $0.kind == .module }!.files.count == 2)
precondition(moduleRows.first { $0.title == "Theme.swift" }!.depth == 2)
precondition(moduleRows.first { $0.kind == .section && $0.title == "Ignored Files" }!.count == 2)
precondition(moduleRows.filter { $0.kind == .ignored }.count == 2)
precondition(moduleRows.filter { $0.kind == .ignored || $0.id == "Ignored Files" }.allSatisfy { $0.files.isEmpty },
  "Ignored entries must never be included in commit, stage or rollback selections")
precondition(directoryRows.filter { $0.kind == .section }.map(\.title) == ["Conflicts", "Changes", "Unversioned Files", "Ignored Files"])
do {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitdesk-modules-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root.appendingPathComponent(".idea"), withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  precondition(CommitModule.discover(in: root) == [CommitModule(name: root.lastPathComponent, root: "")])
  try Data("""
    <project><modules>
      <module filepath="$PROJECT_DIR$/.idea/app.iml"/>
      <module fileurl="file://$PROJECT_DIR$/.idea/nested.iml"/>
      <module filepath="/outside/repository.iml"/>
    </modules></project>
    """.utf8).write(to: root.appendingPathComponent(".idea/modules.xml"))
  try Data("""
    <module><content url="file://$MODULE_DIR$/../Sources/App"/></module>
    """.utf8).write(to: root.appendingPathComponent(".idea/app.iml"))
  try Data("""
    <module><content url="file://$PROJECT_DIR$/Sources/App/Nested"/></module>
    """.utf8).write(to: root.appendingPathComponent(".idea/nested.iml"))
  let modules = CommitModule.discover(in: root)
  precondition(modules.map(\.name) == ["nested", "app"])
  let nestedFiles = [FileChange(path: "Sources/App/Nested/hello.swift", worktree: "M")]
  let rows = CommitChanges.rows(changes: nestedFiles, ignored: [], modules: modules,
    directories: true, byModule: true, collapsed: [])
  precondition(rows.first { $0.kind == .module }!.title == "nested", "Use the most specific module root")
  precondition(rows.first { $0.file != nil }!.title == "hello.swift")
}
print("Commit view options: directory/module grouping, compaction, collapse, selection identity and read-only ignored entries passed")

// Hiding metadata must reclaim its width and preserve adjacent resize behavior.
resizeTable.tableColumns[2].isHidden = true
resizeTable.fitColumns()
precondition(abs(resizeTable.tableColumns.filter { !$0.isHidden }.map(\.width).reduce(0, +)
  - resizeScroll.contentSize.width) < 0.5)
let hiddenAuthorWidth = resizeTable.tableColumns[2].width
let beforeHiddenDrag = resizeTable.tableColumns[3].width
dragBoundary(1, by: -10)
precondition(resizeTable.tableColumns[2].width == hiddenAuthorWidth)
precondition(resizeTable.tableColumns[3].width == beforeHiddenDrag + 10)
resizeTable.tableColumns[3].isHidden = true
resizeTable.fitColumns()
precondition(abs(resizeTable.tableColumns[1].width + resizeTable.tableColumns[0].width
  - resizeScroll.contentSize.width) < 0.5)
resizeTable.tableColumns[2].isHidden = false
resizeTable.tableColumns[3].isHidden = false
resizeTable.fitColumns()
precondition(resizeTable.tableColumns[2].width == hiddenAuthorWidth)

let historicalFiles = commitFiles.filter { !$0.isUntracked && !$0.isConflicted }
let detailTree = DetailFiles.tree(historicalFiles, modules: [], directories: true, byModule: false)
precondition(detailTree.first!.title == "Sources/GitDesk")
precondition(detailTree.first!.children.count == 2)
precondition(Set(detailTree.flatMap(\.files).map(\.path)) == Set(historicalFiles.map(\.path)))
let flatDetail = DetailFiles.tree(historicalFiles, modules: [], directories: false, byModule: false)
precondition(flatDetail.allSatisfy { $0.file != nil })
precondition(flatDetail.contains { $0.title == "Sources/GitDesk/Theme.swift" })
let moduleDetail = DetailFiles.tree(historicalFiles,
  modules: [CommitModule(name: "app", root: "Sources/GitDesk")], directories: true, byModule: true)
precondition(moduleDetail.first!.kind == .module && moduleDetail.first!.title == "app")
precondition(moduleDetail.first!.files.count == 2)
precondition(Set(moduleDetail.flatMap(\.files).map(\.path)) == Set(historicalFiles.map(\.path)))
precondition(directoryRows.first { $0.id == "Ignored Files" }!.paths.sorted() == [".env", "cache/"])
precondition(directoryRows.first { $0.id == "Ignored Files" }!.files.isEmpty)
print("Other view options: historical directory/module/flat trees, hidden column resizing and ignored path selection passed")

resizeTable.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
resizeTable.reloadKeepingSelection()
precondition(resizeTable.selectedRowIndexes == IndexSet([0, 1]),
  "Changing Log appearance must retain every selected commit")
print("Log appearance refresh preserves multiple selected commits")

// Exercise the actual conflict editor: deleted sides and empty files must differ.
do {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gitdesk-conflict-ui-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  for scenario in ["delete-ours", "delete-theirs", "empty-file", "edited-result"] {
    let root = directory.appendingPathComponent(scenario)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repo = GitRepository(directory: root)
    try repo.run(["init", "-b", "main"])
    try repo.run(["config", "user.name", "Conflict Test"])
    try repo.run(["config", "user.email", "conflict@example.test"])
    try repo.run(["config", "commit.gpgsign", "false"])
    try repo.run(["config", "core.hooksPath", "/dev/null"])
    let path = "file [literal].txt"
    let url = root.appendingPathComponent(path)
    try Data("base\n".utf8).write(to: url)
    try repo.run(["add", "--", path]); try repo.run(["commit", "-m", "Base"])
    try repo.run(["switch", "-c", "modified"])
    try Data((scenario == "empty-file" ? "" : "modified\n").utf8).write(to: url)
    try repo.run(["commit", "-am", "Modify"])
    try repo.run(["switch", "main"])
    if scenario == "empty-file" {
      try Data("other content\n".utf8).write(to: url)
      try repo.run(["commit", "-am", "Modify differently"])
    } else {
      try repo.run(["rm", "--", path]); try repo.run(["commit", "-m", "Delete"])
    }
    if scenario == "delete-theirs" { try repo.run(["switch", "modified"]) }
    try repo.run(["merge", "--no-edit", scenario == "delete-theirs" ? "main" : "modified"], allowFailure: true)
    let file = try repo.status().first(where: \.isConflicted)!
    let controller = ConflictWindowController(repository: repo, file: file)
    func waitUntil(_ condition: () -> Bool) {
      let deadline = Date().addingTimeInterval(15)
      while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
      }
      precondition(condition(), "Conflict editor timed out: " + scenario)
    }
    waitUntil { controller.isLoaded }
    precondition(!controller.binaryConflict)
    controller.useSide(scenario == "delete-theirs" || scenario == "empty-file" ? 3 : 2)
    if scenario == "edited-result" {
      controller.result.string = "manual resolution\n"
      controller.textDidChange(Notification(name: NSText.didChangeNotification))
    }
    var resolved = false
    controller.onResolve = { resolved = true }
    controller.save()
    waitUntil { resolved }
    let retainsFile = scenario == "empty-file" || scenario == "edited-result"
    precondition(FileManager.default.fileExists(atPath: url.path) == retainsFile)
    let status = try repo.status()
    precondition(status.allSatisfy { !$0.isConflicted })
    if retainsFile {
      let contents = try Data(contentsOf: url)
      precondition(contents == Data((scenario == "empty-file" ? "" : "manual resolution\n").utf8))
    } else {
      let tracked = try repo.run(["ls-files", "-z", "--", path])
      precondition(tracked.isEmpty)
    }
  }
  print("Conflict editor: deleted ours/theirs, real empty files and editing after side selection passed")
} catch {
  print("FAIL Conflict editor: " + error.localizedDescription)
  exit(1)
}

// Validate the actual filled contour at every selected-row boundary. Neighbor
// flags are AppKit's; changing them must also invalidate an already visible row.
do {
  let selection = SelectionRow(frame: NSRect(x: 0, y: 0, width: 200, height: 25))
  let selectionWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 25),
    styleMask: [.borderless], backing: .buffered, defer: false)
  selectionWindow.isReleasedWhenClosed = false
  selectionWindow.contentView!.addSubview(selection)
  defer { selectionWindow.close() }
  selection.isSelected = true
  precondition(!selection.selectionShape.contains(NSPoint(x: 4.1, y: 0.1)))
  precondition(!selection.selectionShape.contains(NSPoint(x: 195.9, y: 24.9)))
  selection.needsDisplay = false
  selection.isNextRowSelected = true
  precondition(selection.selectionShape.contains(NSPoint(x: 4.1, y: 24.9)))
  precondition(selection.selectionShape.contains(NSPoint(x: 195.9, y: 24.9)))
  selection.isPreviousRowSelected = true
  precondition(selection.selectionShape.contains(NSPoint(x: 4.1, y: 0.1)))
  precondition(selection.selectionShape.contains(NSPoint(x: 195.9, y: 0.1)))
  selection.isNextRowSelected = false
  precondition(!selection.selectionShape.contains(NSPoint(x: 4.1, y: 24.9)))
  precondition(selection.selectionShape.contains(NSPoint(x: 4.1, y: 0.1)))
  selection.isPreviousRowSelected = false
  precondition(!selection.selectionShape.contains(NSPoint(x: 4.1, y: 0.1)))
}
print("Selection contours: rounded isolated rows, straight adjacent edges, both ends and live neighbor invalidation passed")

// Selection must not punch a plain-background border into a tinted branch row.
do {
  let originalTheme = Theme.current
  defer { Theme.current = originalTheme }
  let row = SelectionRow(frame: NSRect(x: 0, y: 0, width: 200, height: 25))
  let window = NSWindow(contentRect: row.frame, styleMask: [.borderless], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView!.addSubview(row)
  defer { window.close() }
  row.selectionHighlightStyle = .regular
  row.isEmphasized = true
  func sample(_ x: Int, _ y: Int) -> NSColor {
    let bitmap = row.bitmapImageRepForCachingDisplay(in: row.bounds)!
    row.cacheDisplay(in: row.bounds, to: bitmap)
    return bitmap.colorAt(x: x * bitmap.pixelsWide / 200, y: y * bitmap.pixelsHigh / 25)!.usingColorSpace(.sRGB)!
  }
  for theme in AppTheme.allCases {
    Theme.current = theme
    window.appearance = theme.appearance
    row.backgroundColor = Theme.background
    row.backgroundTint = Theme.currentBranchBackground
    row.isSelected = false
    let margin = sample(1, 12), corner = sample(4, 0)
    row.isSelected = true
    precondition(sample(1, 12) == margin && sample(4, 0) == corner,
      "Rounded commit selection must retain the underlying branch tint")
    precondition(sample(100, 12) != margin, "The center still uses selection color")
  }
}
print("Tinted commit selection: branch backgrounds survive outside selection corners in all four themes")

do {
  let formatter = LogDateFormatter()
  let iso = ISO8601DateFormatter()
  func date(_ value: String) -> Date { iso.date(from: value)! }
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
  let now = date("2026-10-13T16:00:00+08:00")
  for (seconds, expected) in [(0.0, "Moments ago"), (30, "Moments ago"),
    (31, "A minute ago"), (60, "A minute ago"), (90, "2 minutes ago"),
    (300, "5 minutes ago"), (3540, "59 minutes ago"), (3570, "1 hour ago"),
    (3600, "1 hour ago"), (3660, "1 hour ago"), (3661, "Today 14:58")] {
    precondition(formatter.string(now.addingTimeInterval(-seconds), now: now, calendar: calendar) == expected,
      "IDEA recent-time rounding and 61-minute boundary: \(seconds)")
  }
  for (timestamp, expected) in [
    ("2026-10-13T09:00:00+08:00", "Today 09:00"),
    ("2026-10-12T14:53:00+08:00", "Yesterday 14:53"),
    ("2026-10-08T15:36:00+08:00", "2026/10/8 15:36"),
    ("2026-10-13T17:00:00+08:00", "Today 17:00"),
    ("2026-10-14T17:00:00+08:00", "2026/10/14 17:00")] {
    precondition(formatter.string(date(timestamp), now: now, calendar: calendar) == expected)
  }
  precondition(formatter.string(date("2025-12-31T14:53:00+08:00"),
    now: date("2026-01-01T16:00:00+08:00"), calendar: calendar) == "Yesterday 14:53")
  precondition(formatter.string(date("2025-12-31T23:55:00+08:00"),
    now: date("2026-01-01T00:10:00+08:00"), calendar: calendar) == "15 minutes ago")
  calendar.timeZone = TimeZone(identifier: "America/New_York")!
  precondition(formatter.string(date("2026-03-08T00:45:00-05:00"),
    now: date("2026-03-09T00:30:00-04:00"), calendar: calendar) == "Yesterday 00:45")
  precondition(formatter.string(Date(timeIntervalSince1970: -1), now: now, calendar: calendar).isEmpty)
}
print("Log dates: IDEA minute rounding, today/yesterday, absolute dates, future timestamps, year rollover and daylight saving passed")

// The terminal is a real PTY: exercise cwd, ANSI/Unicode, resize, Ctrl-C,
// independent sessions, and process cleanup without reading user shell profiles.
do {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitdesk terminal ' " + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let workspace = TerminalWorkspace(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
  let window = NSWindow(contentRect: workspace.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false; window.contentView = workspace
  defer { workspace.shutdown(); window.close() }
  workspace.repositoryURL = root
  window.contentView!.layoutSubtreeIfNeeded()
  workspace.newSession(executable: "/bin/sh", arguments: [])
  let terminal = workspace.activeTerminal!
  func send(_ string: String) { let bytes = Array(string.utf8); terminal.send(source: terminal, data: bytes[...]) }
  func text() -> String { String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "") }
  func waitFor(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(8)
    while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    if !condition() { FileHandle.standardError.write(Data(("PTY timeout: " + text() + "\n").utf8)) }
    precondition(condition(), "PTY operation timed out")
  }
  send("printf '\\033[31mPTY_%s\\033[0m\\n' READY; pwd; printf '\\344\\270\\255\\346\\226\\207\\n'\r")
  waitFor { text().contains("PTY_READY") && text().replacingOccurrences(of: "\n", with: "").contains(root.path) && text().contains("中文") }
  let oldCols = terminal.getTerminal().cols
  window.setContentSize(NSSize(width: 1000, height: 500)); workspace.layoutSubtreeIfNeeded()
  waitFor { terminal.getTerminal().cols > oldCols }
  send("sleep 30\r")
  RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  send("\u{3}printf 'INTERRUPT_%s\\n' OK\r")
  waitFor { text().contains("INTERRUPT_OK") }
  workspace.newSession(executable: "/bin/sh", arguments: [])
  precondition(workspace.sessionCount == 2 && workspace.activeTerminal !== terminal && terminal.process.running)
  workspace.shutdown()
  waitFor { !terminal.process.running }
  precondition(workspace.sessionCount == 0)
}
print("Embedded terminal: PTY cwd with special characters, ANSI/Unicode, resize, Ctrl-C, sessions and cleanup passed")
