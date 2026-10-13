import AppKit
import GitDeskCore

func runHistoryPaginationChecks() throws {
  func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
  }
  func waitUntil(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(20)
    while !condition() && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(condition(), "History pagination timed out")
  }
  func drain(_ queue: DispatchQueue) {
    for _ in 0..<2 {
      var done = false
      queue.async { DispatchQueue.main.async { done = true } }
      waitUntil { done }
    }
  }
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gitdesk-paging-ui-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repo = GitRepository(directory: directory)
  try repo.run(["init", "-b", "main"])
  try repo.run(["config", "user.name", "Paging Test"])
  try repo.run(["config", "user.email", "paging@example.test"])
  try repo.run(["config", "commit.gpgsign", "false"])
  try repo.run(["config", "core.hooksPath", "/dev/null"])
  var stream = ""
  for index in 0..<4501 {
    let message = "\(index % 2 == 0 ? "needle" : "ordinary") \(index)"
    stream += "commit refs/heads/main\ncommitter Paging Test <paging@example.test> \(1700000000 + index) +0000\ndata \(message.utf8.count)\n\(message)\n\n"
  }
  let input = directory.appendingPathComponent(".git/paging-import")
  try Data(stream.utf8).write(to: input)
  let handle = try FileHandle(forReadingFrom: input)
  defer { try? handle.close() }
  let task = Process()
  task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  task.arguments = ["fast-import", "--quiet"]
  task.currentDirectoryURL = directory
  task.standardInput = handle; task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
  try task.run(); task.waitUntilExit()
  check(task.terminationStatus == 0, "Import paginated history")
  let root = try repo.resolve("HEAD~4500")
  try repo.run(["branch", "root-only", root])
  let controller = RepositoryController()
  _ = controller.view
  controller.watcher?.invalidate()
  controller.repository = repo
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = controller.view
  window.orderBack(nil)
  defer { window.close() }
  controller.refresh(silent: true); drain(controller.queue)
  check(controller.snapshot!.commits.count == 2000 && controller.snapshot!.hasMoreCommits,
    "Initial log loads only the first batch")
  controller.logTable.selectRowIndexes(IndexSet([10, 30]), byExtendingSelection: false)
  drain(controller.queue)
  let selected = Set(controller.logTable.selectedRowIndexes.map { controller.displayedLogCommits[$0].hash })
  controller.commitMessage.string = "Keep this draft"
  let gate = DispatchSemaphore(value: 0)
  controller.queue.async { gate.wait() }
  controller.logTable.scrollRowToVisible(1999)
  controller.logTable.enclosingScrollView!.reflectScrolledClipView(controller.logTable.enclosingScrollView!.contentView)
  waitUntil { controller.isLoadingMoreHistory }
  for _ in 0..<10 { controller.loadMoreHistory() }
  check(controller.filter.limit == 2000, "Duplicate scroll requests do not grow the in-flight limit")
  let anchorRow = controller.logTable.rows(in: controller.logTable.visibleRect).location
  let anchor = controller.displayedLogCommits[anchorRow].hash
  let oldOffset = controller.logTable.visibleRect.minY - controller.logTable.rect(ofRow: anchorRow).minY
  // Replacing the prefix must also be safe when another process adds a commit.
  try repo.run(["commit", "--allow-empty", "-m", "external new commit"])
  gate.signal(); drain(controller.queue)
  check(controller.snapshot!.commits.count == 4000 && controller.filter.limit == 4000,
    "Scrolling near the bottom loads one more batch")
  check(Set(controller.snapshot!.commits.map(\.hash)).count == 4000,
    "External HEAD changes do not duplicate rows")
  check(Set(controller.logTable.selectedRowIndexes.map { controller.displayedLogCommits[$0].hash }) == selected,
    "Pagination retains every selected commit by hash")
  let newRow = controller.logTable.rows(in: controller.logTable.visibleRect).location
  check(controller.displayedLogCommits[newRow].hash == anchor,
    "Pagination keeps the same top visible commit after an external insertion")
  check(abs(controller.logTable.visibleRect.minY - controller.logTable.rect(ofRow: newRow).minY - oldOffset) < 1,
    "Pagination retains the intra-row scroll offset")
  check(controller.commitMessage.string == "Keep this draft", "Pagination preserves the commit draft")
  func signature(_ rows: [GraphRow]) -> [String] {
    rows.map { row in "\(row.lane):\(row.color):" + row.edges.map { "\($0.from),\($0.to),\($0.color)" }.joined(separator: ";") }
  }
  let expectedGraph = RepositoryHistoryPresentation.prepare(controller.snapshot!)
  check(signature(controller.graphs) == signature(expectedGraph.graphs),
    "Appended history keeps the graph equivalent to one complete load")
  controller.refresh(silent: true); drain(controller.queue)
  check(controller.filter.limit == 4000 && controller.snapshot!.commits.count == 4000,
    "Regular refresh retains the already loaded history depth")
  controller.logTable.scrollRowToVisible(3999)
  waitUntil { controller.isLoadingMoreHistory }
  drain(controller.queue)
  check(controller.snapshot!.commits.count == 4502 && !controller.snapshot!.hasMoreCommits,
    "Scrolling again reaches the repository's actual end")
  let endFilter = controller.filter
  controller.loadMoreHistory(); drain(controller.queue)
  check(controller.filter == endFilter && !controller.isLoadingMoreHistory,
    "Exhausted history stops requesting more")

  controller.filter.text = "needle"; controller.refresh(silent: true, logOnly: true)
  drain(controller.queue)
  check(controller.filter.limit == 2000 && controller.snapshot!.commits.count == 2000 && controller.snapshot!.hasMoreCommits,
    "Changing search resets pagination and looks ahead among matches")
  check(controller.logTable.visibleRect.minY < 1,
    "Changing filters resets the viewport so the old bottom cannot trigger extra pages")
  controller.loadMoreHistory(); drain(controller.queue)
  check(controller.snapshot!.commits.count == 2251 && !controller.snapshot!.hasMoreCommits,
    "Search pagination loads older matches beyond the initial result limit")
  controller.filter.text = ""; controller.refresh(silent: true, logOnly: true); drain(controller.queue)
  let staleGate = DispatchSemaphore(value: 0)
  controller.queue.async { staleGate.wait() }
  controller.loadMoreHistory()
  check(controller.isLoadingMoreHistory, "Start an obsolete page request")
  controller.filter.branch = "root-only"
  controller.refresh(silent: true, logOnly: true)
  staleGate.signal(); drain(controller.queue)
  check(controller.filter.limit == 2000 && controller.snapshot!.commits.map(\.hash) == [root]
    && !controller.isLoadingMoreHistory, "A filter change discards the obsolete page without mixing results")

  controller.filter.branch = nil; controller.refresh(silent: true, logOnly: true); drain(controller.queue)
  let failureGate = DispatchSemaphore(value: 0)
  controller.queue.async { failureGate.wait() }
  controller.loadMoreHistory()
  let git = directory.appendingPathComponent(".git"), savedGit = directory.appendingPathComponent("saved-git")
  try FileManager.default.moveItem(at: git, to: savedGit)
  failureGate.signal(); drain(controller.queue)
  try FileManager.default.moveItem(at: savedGit, to: git)
  check(!controller.isLoadingMoreHistory && controller.filter.limit == 2000
    && controller.snapshot!.commits.count == 2000 && controller.statusLabel.stringValue.contains("Could not load older commits"),
    "A failed page preserves current rows and remains retryable")
  controller.loadMoreHistory(); drain(controller.queue)
  check(controller.snapshot!.commits.count == 4000, "Retrying a failed page succeeds")

  let defaults = UserDefaults.standard
  let keys = ["recentRepositories", "lastRepository"]
  let saved = keys.map { defaults.object(forKey: $0) }
  defer { for (key, value) in zip(keys, saved) {
    if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
  } }
  let otherURL = directory.appendingPathComponent("other")
  try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
  let other = GitRepository(directory: otherURL)
  try other.run(["init", "-b", "main"])
  try other.run(["-c", "user.name=Other", "-c", "user.email=other@example.test", "-c", "commit.gpgsign=false",
    "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "Other repository"])
  let switchGate = DispatchSemaphore(value: 0)
  controller.queue.async { switchGate.wait() }
  controller.loadMoreHistory()
  controller.open(otherURL)
  switchGate.signal(); drain(controller.queue)
  check(controller.repository!.workingDirectory.resolvingSymlinksInPath() == otherURL.resolvingSymlinksInPath()
    && controller.snapshot!.commits.map(\.subject) == ["Other repository"]
    && controller.filter.limit == 2000 && !controller.isLoadingMoreHistory,
    "Switching repositories discards pages from the previous repository")
  print("History pagination: actual scrolling, end detection, search, graph/selection/viewport preservation, refresh, failure/retry and stale requests passed")
}
