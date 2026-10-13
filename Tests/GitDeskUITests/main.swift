import AppKit
import GitDeskCore

defer {
  do { try runHistoryPaginationChecks(); try runFlowChecks() }
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
    precondition(matches(pixel(31, 20), branch), "The side-branch dot uses its branch color")
    precondition(matches(pixel(31, 10), branch), "The side-branch line matches its dot in " + theme.title)
    precondition(matches(pixel(16, 10), Theme.graph[rows[0].color % Theme.graph.count]),
      "A main connection passing through a side-branch row keeps its own color")
  }
  print("Graph rendering: branch dots/lines and passing main connections match in all four themes")
}
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
