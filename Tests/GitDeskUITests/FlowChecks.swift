import AppKit
import GitDeskCore

func runFlowChecks() throws {
  var failures: [String] = []
  func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message); print("FAIL " + message) }
  }
  func drain(_ queue: DispatchQueue) {
    // File delivery can schedule a second background job to compute the diff.
    for _ in 0..<2 {
      var done = false
      queue.async { DispatchQueue.main.async { done = true } }
      let deadline = Date().addingTimeInterval(15)
      while !done && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
      }
      precondition(done, "Background operation timed out")
    }
  }
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gitdesk-flows-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repo = GitRepository(directory: directory)
  try repo.run(["init", "-b", "main"])
  try repo.run(["config", "user.name", "Flow Test"])
  try repo.run(["config", "user.email", "flow@example.test"])
  try repo.run(["config", "commit.gpgsign", "false"])
  try repo.run(["config", "core.hooksPath", "/dev/null"])
  func write(_ path: String, _ text: String) throws {
    try Data(text.utf8).write(to: directory.appendingPathComponent(path))
  }
  func commit(_ message: String) throws {
    try repo.run(["add", "."])
    try repo.run(["commit", "--allow-empty", "-m", message])
  }
  try write("first.txt", "one\ntwo\nthree\n")
  try write("space.txt", "value = 1\n")
  try commit("Initial")
  try commit("Current subject\n\nCurrent body")
  let head = try repo.commit(at: "HEAD")
  try repo.run(["branch", "feature/older", "HEAD~1"])
  try write("first.txt", "ONE\ntwo\nTHREE\n")
  try write("space.txt", "value   = 1\n")
  let changes = try repo.status()
  let first = changes.first { $0.path == "first.txt" }!
  let space = changes.first { $0.path == "space.txt" }!

  let viewer = DiffViewController()
  viewer.load(repository: repo, change: first)
  drain(viewer.queue)
  viewer.whitespace.state = .on
  viewer.optionsChanged()
  drain(viewer.queue)
  viewer.load(repository: repo, change: space)
  drain(viewer.queue)
  check(viewer.diff?.changes.isEmpty == true && viewer.countLabel.stringValue == "Differences ignored",
    "Ignore whitespace survives file navigation")

  // Hold I/O so changing layout/options occurs while the next file is loading.
  let gate = DispatchSemaphore(value: 0)
  viewer.queue.async { gate.wait() }
  viewer.load(repository: repo, change: first)
  viewer.layoutToggle.selectedSegment = 1
  viewer.optionsChanged()
  viewer.whitespace.state = .off
  viewer.optionsChanged()
  gate.signal()
  drain(viewer.queue)
  drain(viewer.queue)
  check(String(decoding: viewer.after, as: UTF8.self) == "ONE\ntwo\nTHREE\n",
    "Changing diff options during loading keeps the requested file")
  check(viewer.diff?.identical == false && !viewer.unifiedLines().isEmpty,
    "Changing diff layout during loading renders the requested diff")
  viewer.clear()
  viewer.optionsChanged()
  drain(viewer.queue)
  check(viewer.diff == nil && viewer.emptyLabel.stringValue == "Select a file to view its changes",
    "Changing options without a file preserves the empty state")

  let controller = RepositoryController()
  let savedFavorites = UserDefaults.standard.object(forKey: "favoriteRefs")
  defer {
    if let savedFavorites { UserDefaults.standard.set(savedFavorites, forKey: "favoriteRefs") }
    else { UserDefaults.standard.removeObject(forKey: "favoriteRefs") }
  }
  _ = controller.view
  controller.watcher?.invalidate()
  controller.repository = repo
  var filtered = LogFilter()
  filtered.text = "Initial"
  controller.snapshot = try repo.snapshot(filter: filtered)
  controller.updateUI()
  controller.amend.state = .on
  controller.amendChanged()
  drain(controller.queue)
  check(controller.commitMessage.string == head.fullMessage,
    "Amend loads HEAD's message even when the log filter hides HEAD")
  controller.commitMessage.string = ""
  let amendGate = DispatchSemaphore(value: 0)
  controller.queue.async { amendGate.wait() }
  controller.amendChanged()
  controller.commitMessage.string = "New draft while reading HEAD"
  amendGate.signal()
  drain(controller.queue)
  check(controller.commitMessage.string == "New draft while reading HEAD",
    "Delayed Amend delivery never overwrites a newly typed draft")
  controller.amend.state = .off
  controller.amendChanged()
  check(controller.commitMessage.string.isEmpty, "Cancelling Amend restores the previous empty draft")
  controller.commitMessage.string = "Original draft"
  controller.amend.state = .on
  controller.amendChanged()
  drain(controller.queue)
  check(controller.commitMessage.string == head.fullMessage,
    "Amend temporarily replaces an existing draft with HEAD's message, as in IDEA")
  controller.amend.state = .off
  controller.amendChanged()
  check(controller.commitMessage.string == "Original draft", "Cancelling Amend restores the original draft")

  controller.snapshot = try repo.snapshot()
  controller.updateUI()
  controller.logTable.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
  check(controller.selectedCommit?.hash == head.hash,
    "Multiple selection shows the topmost selected commit, as in IDEA")
  let selected = Set(controller.snapshot!.commits.map(\.hash))
  try commit("New commit above selection")
  controller.snapshot = try repo.snapshot()
  controller.updateUI()
  let refreshed = Set(controller.logTable.selectedRowIndexes.map { controller.snapshot!.commits[$0].hash })
  check(refreshed == selected, "Refreshing preserves every selected commit by hash")
  drain(controller.queue)

  check(controller.branchHeadButton?.isEnabled == false,
    "Branch-head navigation stays disabled without a branch selection")
  let branchRow = (0..<controller.branchOutline.numberOfRows).first {
    (controller.branchOutline.item(atRow: $0) as? BranchNode)?.branch?.name == "feature/older"
  }!
  controller.branchOutline.selectRowIndexes(IndexSet(integer: branchRow), byExtendingSelection: false)
  check(controller.branchHeadButton?.isEnabled == true, "Selecting a branch enables head navigation")
  controller.navigateSelectedBranchHead()
  drain(controller.queue)
  let branchHead = try repo.resolve("feature/older")
  check(controller.selectedCommit?.hash == branchHead,
    "Branch-head navigation selects that branch's tip in the log")
  check(controller.selectedBranch?.name == "feature/older" && controller.filter.branch == nil,
    "Branch-head navigation preserves branch selection and an unfiltered log")
  let olderBranch = controller.selectedBranch!
  let wasFavorite = controller.favoriteRefs.contains(olderBranch.fullRef)
  controller.branchFavoriteButton?.handler?()
  check(controller.favoriteRefs.contains(olderBranch.fullRef) != wasFavorite && !controller.favoriteOnly,
    "The branch star toggles the selected branch's favorite instead of filtering branches")
  check(controller.selectedBranch?.fullRef == olderBranch.fullRef,
    "Toggling a branch favorite preserves its selection")
  controller.branchFavoriteButton?.handler?()
  check(controller.favoriteRefs.contains(olderBranch.fullRef) == wasFavorite,
    "The branch star can unmark the same favorite")

  // A filtered-out selection must also invalidate already queued detail reads.
  let detailsGate = DispatchSemaphore(value: 0)
  controller.queue.async { detailsGate.wait() }
  controller.logTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  var empty = LogFilter()
  empty.text = "no matching commit"
  controller.snapshot = try repo.snapshot(filter: empty)
  controller.updateUI()
  detailsGate.signal()
  drain(controller.queue)
  check(controller.selectedCommit == nil && controller.detailFiles.isEmpty && controller.loadedDetailHash == nil,
    "Filtered-out commits cannot restore stale details after loading")

  try write("first.txt", "ONE\ntwo\nTHREE\nfour\n")
  try write("space.txt", "new value\n")
  controller.snapshot = try repo.snapshot()
  controller.updateUI()
  let firstRow = controller.workingRows.firstIndex { $0.file?.path == "first.txt" }!
  controller.changesTable.selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
  controller.previewWorkingDiff()
  check(controller.inlineDiff?.nextFile != nil && controller.inlineDiff?.previousFile != nil,
    "Commit preview file navigation is connected")
  controller.inlineDiff?.nextFile?()
  check(controller.inlineDiff?.titleLabel.stringValue == "space.txt",
    "Next File changes both the Commit selection and its preview")
  controller.inlineDiff?.previousFile?()
  check(controller.inlineDiff?.titleLabel.stringValue == "first.txt",
    "Previous File returns to the preceding changed file")
  if let preview = controller.inlineDiff { drain(preview.queue) }
  if !failures.isEmpty { throw GitFailure(failures.joined(separator: "\n")) }
  print("Functional flows: diff options/loading, filtered amend/draft safety, refresh/filter selection, branch-head and Commit file navigation passed")
}
