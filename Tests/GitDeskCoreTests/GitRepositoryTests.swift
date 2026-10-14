import Foundation
import GitDeskCore

final class GitRepositoryTests: TestHarness {
  var directory: URL!
  var repo: GitRepository!
  func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "gitdesk-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    repo = GitRepository(directory: directory)
    try repo.run(["init", "-b", "main"])
    try repo.run(["config", "user.name", "Test User"])
    try repo.run(["config", "user.email", "test@example.test"])
    try repo.run(["config", "commit.gpgsign", "false"])
    try repo.run(["config", "core.hooksPath", "/dev/null"])
  }
  func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
  func write(_ path: String, _ text: String) throws {
    let url = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }
  func commitAll(_ message: String) throws {
    try repo.run(["add", "."])
    try repo.run(["commit", "-m", message])
  }
  func testUnbornRepositoryAndInitialCommit() throws {
    let snapshot = try repo.snapshot()
    XCTAssertEqual(snapshot.currentBranch, "main")
    XCTAssertEqual(snapshot.branches.first?.name, "main")
    XCTAssertTrue(snapshot.commits.isEmpty)
    try write("hello.txt", "Initial stage\n")
    try repo.stage(repo.status())
    try write("hello.txt", "Hello\n")
    try repo.unstage(repo.status())
    XCTAssertTrue(try repo.status()[0].isUntracked)
    XCTAssertEqual(
      try String(contentsOf: directory.appendingPathComponent("hello.txt"), encoding: .utf8),
      "Hello\n")
    try repo.commit(message: "Initial", changes: repo.status())
    XCTAssertEqual(try repo.log().first?.subject, "Initial")
    XCTAssertTrue(try repo.status().isEmpty)
    XCTAssertEqual(try repo.changes(in: XCTUnwrap(repo.log().first)).map(\.path), ["hello.txt"])
  }
  func testIgnoredFilesAreReadOnlyAndCollapsed() throws {
    try write(".gitignore", "cache/\nsecret*\n*.tmp\n")
    try write("tracked.tmp", "tracked\n")
    try repo.run(["add", "-f", "tracked.tmp"])
    try commitAll("Ignore generated files")
    try write("cache/deep/output.bin", "generated\n")
    try write("secret\n中文.txt", "ignored\n")
    try write("scratch.tmp", "ignored\n")
    try write("visible.txt", "unversioned\n")
    try write("tracked.tmp", "modified\n")
    let index = try repo.runData(["ls-files", "--stage", "-z"])
    let status = try repo.status()
    XCTAssertEqual(Set(try repo.ignoredPaths()), ["cache/", "secret\n中文.txt", "scratch.tmp"])
    XCTAssertEqual(Set(status.map(\.path)), ["tracked.tmp", "visible.txt"])
    XCTAssertEqual(try repo.runData(["ls-files", "--stage", "-z"]), index)
    XCTAssertEqual(try repo.status(), status)
  }
  func testSelectedCommitPreservesUnrelatedStaging() throws {
    try write("a.txt", "one\n")
    try write("b.txt", "one\n")
    try commitAll("Initial")
    try write("a.txt", "two\n")
    try write("b.txt", "two\n")
    try repo.stage(repo.status().filter { $0.path == "b.txt" })
    try repo.commit(message: "Only A", changes: repo.status().filter { $0.path == "a.txt" })
    XCTAssertEqual(
      String(decoding: try repo.blob(ref: "HEAD", path: "a.txt"), as: UTF8.self), "two\n")
    XCTAssertEqual(
      String(decoding: try repo.blob(ref: "HEAD", path: "b.txt"), as: UTF8.self), "one\n")
    let changes = try repo.status()
    XCTAssertEqual(changes.count, 1)
    XCTAssertEqual(changes[0].path, "b.txt")
    XCTAssertTrue(changes[0].isStaged)
  }
  func testFailedCommitPreservesIndexAndWorkingTree() throws {
    try write("tracked", "one")
    try commitAll("Initial")
    try write("tracked", "two")
    try write("new", "new")
    try repo.run(["config", "user.name", ""])
    try repo.run(["config", "user.email", ""])
    let before = try repo.runData(["ls-files", "--stage", "-z"])
    XCTAssertThrowsError(try repo.commit(message: "Fail", changes: repo.status()))
    XCTAssertEqual(before, try repo.runData(["ls-files", "--stage", "-z"]))
    XCTAssertEqual(
      try String(contentsOf: directory.appendingPathComponent("tracked"), encoding: .utf8), "two")
  }
  func testCommitAuthorAndSignOff() throws {
    try write("a", "one")
    try write("unrelated", "staged")
    try repo.stage(repo.status().filter { $0.path == "unrelated" })
    try repo.commit(message: "Custom author", changes: repo.status().filter { $0.path == "a" },
      author: "Example Author <author@example.test>", signOff: true)
    XCTAssertEqual(try repo.run(["log", "-1", "--format=%an <%ae>"]).trimmingCharacters(in: .whitespacesAndNewlines),
      "Example Author <author@example.test>")
    XCTAssertTrue(try repo.run(["log", "-1", "--format=%B"]).contains("Signed-off-by: Test User <test@example.test>"))
    XCTAssertEqual(try repo.status().map(\.path), ["unrelated"])
    XCTAssertTrue(try repo.status()[0].isStaged)
    try repo.commit(message: "Amended", changes: [], amend: true,
      author: "Revised Author <revised@example.test>")
    XCTAssertEqual(try repo.run(["log", "-1", "--format=%an"]).trimmingCharacters(in: .whitespacesAndNewlines), "Revised Author")
    XCTAssertFalse(try repo.run(["log", "-1", "--format=%B"]).contains("Signed-off-by:"))
    try write("a", "two")
    let head = try repo.resolve("HEAD")
    let index = try repo.runData(["ls-files", "--stage", "-z"])
    XCTAssertThrowsError(try repo.commit(message: "Bad author", changes: repo.status().filter { $0.path == "a" },
      author: "invalid author without an email"))
    XCTAssertEqual(try repo.resolve("HEAD"), head)
    XCTAssertEqual(try repo.runData(["ls-files", "--stage", "-z"]), index)
  }
  func testAmendWithoutChangesPreservesUnrelatedStagedFiles() throws {
    try write("a", "one")
    try commitAll("Initial")
    let old = try repo.resolve("HEAD")
    try write("b", "two")
    try repo.stage(repo.status())
    try repo.commit(message: "Amended", changes: [], amend: true)
    XCTAssertNotEqual(old, try repo.resolve("HEAD"))
    XCTAssertEqual(try repo.log().count, 1)
    XCTAssertEqual(try repo.log()[0].subject, "Amended")
    XCTAssertTrue(try repo.status()[0].isStaged)
    XCTAssertEqual(
      try repo.run(["ls-tree", "--name-only", "HEAD"]).trimmingCharacters(
        in: .whitespacesAndNewlines), "a")
  }
  func testNulPathsUnicodeAndLiteralPathspecs() throws {
    let names = [
      "name with spaces.txt", "line\nbreak.txt", "中文文件.txt", ":(glob)*.txt", "$(touch nope).txt",
      "-leading.txt",
    ]
    for name in names { try write(name, "content\n") }
    let changes = try repo.status()
    XCTAssertEqual(Set(changes.map(\.path)), Set(names))
    try repo.commit(message: "Odd paths", changes: changes)
    XCTAssertEqual(Set(try repo.changes(in: repo.log()[0]).map(\.path)), Set(names))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("nope").path))
  }
  func testSymlinkAndPreviewLimits() throws {
    try write("one", "contents one")
    try write("two", "contents two")
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "one")
    try commitAll("Initial")
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "two")
    let pair = try repo.workingDiff(change: FileChange(path: "link"))
    XCTAssertEqual(pair.0, Data("one".utf8))
    XCTAssertEqual(pair.1, Data("two".utf8))
    try Data(repeating: 65, count: 2_000_001).write(to: directory.appendingPathComponent("large"))
    XCTAssertThrowsError(try repo.readWorkingFile("large"))
    try repo.stage(repo.status())
    XCTAssertThrowsError(try repo.blob(ref: ":", path: "large", limit: 2_000_000))
  }
  func testRenameParsingAndSelectedRenameCommit() throws {
    try write("old name.txt", "contents\n")
    try commitAll("Initial")
    try repo.run(["mv", "old name.txt", "new name.txt"])
    let files = try repo.status()
    XCTAssertEqual(files.first?.oldPath, "old name.txt")
    XCTAssertEqual(files.first?.path, "new name.txt")
    try repo.commit(message: "Rename", changes: files)
    let commit = try repo.log()[0]
    XCTAssertEqual(try repo.changes(in: commit)[0].oldPath, "old name.txt")
    let pair = try repo.contents(change: repo.changes(in: commit)[0], commit: commit)
    XCTAssertEqual(pair.0, pair.1)
    XCTAssertTrue(try repo.status().isEmpty)
  }
  func testIndexAndWorkingDiff() throws {
    try write("a", "base\n")
    try commitAll("Initial")
    try write("a", "staged\n")
    try repo.stage(repo.status())
    try write("a", "working\n")
    let change = try repo.status()[0]
    let staged = try repo.contents(change: change, staged: true)
    XCTAssertEqual(staged.0, Data("base\n".utf8))
    XCTAssertEqual(staged.1, Data("staged\n".utf8))
    let working = try repo.contents(change: change)
    XCTAssertEqual(working.0, Data("staged\n".utf8))
    XCTAssertEqual(working.1, Data("working\n".utf8))
    let total = try repo.workingDiff(change: change)
    XCTAssertEqual(total.0, Data("base\n".utf8))
    XCTAssertEqual(total.1, Data("working\n".utf8))
  }
  func testLogMessageRegexCaseAuthorPathAndBranchFilters() throws {
    try write("a", "one")
    try commitAll("Initial\n\nBody with a separator \u{1e} and detail")
    try repo.createBranch("feature/filter")
    try write("b", "two")
    try commitAll("FEATURE two")
    try repo.run(["switch", "main"])
    var filter = LogFilter()
    filter.text = "feature"
    XCTAssertEqual(try repo.log(filter).count, 1)
    filter.matchCase = true
    XCTAssertEqual(try repo.log(filter).count, 0)
    filter.regex = true
    filter.matchCase = false
    filter.text = "feature.*two"
    XCTAssertEqual(try repo.log(filter).count, 1)
    filter.text = "["
    XCTAssertThrowsError(try repo.log(filter))
    filter = LogFilter()
    filter.branch = "main"
    XCTAssertEqual(try repo.log(filter).count, 1)
    filter = LogFilter()
    filter.path = "b"
    XCTAssertEqual(try repo.log(filter).count, 1)
    filter = LogFilter()
    filter.author = "Missing"
    XCTAssertTrue(try repo.log(filter).isEmpty)
    XCTAssertTrue(try repo.log().last!.body.contains("separator"))
  }
  func testBranchAndTagCheckout() throws {
    try write("a", "one")
    try commitAll("Initial")
    try repo.createBranch("feature/test")
    XCTAssertEqual(try repo.snapshot().currentBranch, "feature/test")
    try repo.checkout(try XCTUnwrap(repo.branches().first { $0.name == "main" }))
    XCTAssertEqual(try repo.snapshot().currentBranch, "main")
    try repo.run(["tag", "v1"])
    try repo.checkout(try XCTUnwrap(repo.branches().first { $0.name == "v1" }))
    XCTAssertEqual(try repo.snapshot().currentBranch, "Detached HEAD")
    XCTAssertThrowsError(try repo.createBranch("--bad"))
    XCTAssertThrowsError(try repo.resolve("--all"))
  }
  func testStashAndRestore() throws {
    try write("a", "one")
    try commitAll("Initial")
    try write("a", "two")
    try write("new", "three")
    try repo.run(["stash", "push", "-u", "-m", "Test stash"])
    XCTAssertTrue(try repo.status().isEmpty)
    XCTAssertEqual(try repo.snapshot().stashes.count, 1)
    try repo.run(["stash", "pop"])
    XCTAssertEqual(try repo.status().count, 2)
    XCTAssertTrue(try repo.snapshot().stashes.isEmpty)
  }
  func testLocalRemotePushFetchPull() throws {
    let bare = directory.appendingPathComponent("remote.git")
    let clone = directory.appendingPathComponent("clone")
    try repo.run(["init", "--bare", bare.path])
    try write(".gitignore", "remote.git/\nclone/\n")
    try write("a", "one")
    try commitAll("Initial")
    try repo.run(["remote", "add", "origin", bare.path])
    try repo.run(["push", "-u", "origin", "main"])
    try repo.run(["clone", "-b", "main", bare.path, clone.path])
    let other = try GitRepository(url: clone)
    try write("a", "two")
    try commitAll("Second")
    try repo.run(["push"])
    try other.run(["fetch", "--all", "--prune"])
    try other.run(["pull", "--ff-only"])
    XCTAssertEqual(try other.resolve("HEAD"), try repo.resolve("HEAD"))
  }
  func testConflictDetectionStagesAndAbort() throws {
    try write("a", "base\n")
    try commitAll("Initial")
    try repo.createBranch("feature")
    try write("a", "feature\n")
    try commitAll("Feature")
    try repo.run(["switch", "main"])
    try write("a", "main\n")
    try commitAll("Main")
    XCTAssertThrowsError(try repo.run(["merge", "feature"]))
    XCTAssertTrue(try repo.status()[0].isConflicted)
    XCTAssertEqual(try repo.snapshot().operation, "merge")
    XCTAssertEqual(try repo.blob(ref: ":2", path: "a"), Data("main\n".utf8))
    XCTAssertEqual(try repo.blob(ref: ":3", path: "a"), Data("feature\n".utf8))
    XCTAssertThrowsError(try repo.commit(message: "Bad", changes: repo.status()))
    try repo.run(["merge", "--abort"])
    XCTAssertNil(try repo.snapshot().operation)
  }
  func testMergeCommitKeepsParentsAndUntrackedFiles() throws {
    try write("base", "base")
    try commitAll("Initial")
    try repo.createBranch("feature")
    try write("feature", "new")
    try commitAll("Feature")
    try repo.run(["switch", "main"])
    try repo.run(["merge", "--no-ff", "--no-commit", "feature"])
    try write("unrelated", "local notes")
    XCTAssertThrowsError(try repo.commit(message: "Merge", changes: []))
    try repo.commit(message: "Merge", changes: repo.status().filter { !$0.isUntracked },
      author: "Merge Author <merge@example.test>", signOff: true)
    XCTAssertEqual(try repo.log()[0].parents.count, 2)
    XCTAssertEqual(try repo.log()[0].author, "Merge Author")
    XCTAssertTrue(try repo.log()[0].body.contains("Signed-off-by: Test User <test@example.test>"))
    XCTAssertNil(try repo.snapshot().operation)
    XCTAssertEqual(try repo.status().map(\.path), ["unrelated"])
  }
  func testFilteredSnapshotPreservesRepositoryState() throws {
    try write("base", "one\n")
    try commitAll("Initial")
    try repo.createBranch("feature")
    try write("feature", "two\n")
    try commitAll("Feature")
    try repo.run(["tag", "-a", "-m", "Release", "v1"])
    try repo.run(["switch", "main"])
    try write("base", "three\n")
    try commitAll("Main")
    try write("untracked", "Keep this change\n")
    let original = try repo.snapshot()
    for ref in ["refs/heads/main", "refs/heads/feature", "refs/tags/v1", "HEAD"] {
      var filter = LogFilter()
      filter.branch = ref
      var commands: [String] = []
      repo.onCommand = { command, _, _ in commands.append(command) }
      let filtered = try repo.filteredSnapshot(from: original, filter: filter)
      repo.onCommand = nil
      XCTAssertEqual(filtered.commits, try repo.log(filter))
      XCTAssertEqual(filtered.history, original.history)
      XCTAssertEqual(filtered.graphAncestry, original.graphAncestry)
      XCTAssertEqual(filtered.branches, original.branches)
      XCTAssertEqual(filtered.changes, original.changes)
      XCTAssertEqual(filtered.currentBranch, original.currentBranch)
      XCTAssertTrue(commands.count <= 3)
      XCTAssertFalse(commands.contains { $0.hasPrefix("git status") || $0.hasPrefix("git stash") })
    }
    var search = LogFilter()
    search.text = "FEATURE"
    XCTAssertEqual(try repo.filteredSnapshot(from: original, filter: search).commits.map(\.subject), ["Feature"])
    search.regex = true
    search.text = "["
    XCTAssertThrowsError(try repo.filteredSnapshot(from: original, filter: search))
    search.regex = false
    search.text = ""
    search.branch = "refs/heads/missing"
    XCTAssertThrowsError(try repo.filteredSnapshot(from: original, filter: search))
    XCTAssertEqual(try repo.status(), original.changes)
  }
  func testOldBranchGraphBeyondLogLimit() throws {
    try write("base", "base\n")
    try commitAll("Base")
    try repo.createBranch("old-side")
    try write("side", "side\n")
    try commitAll("Side")
    try repo.run(["switch", "main"])
    try repo.run(["merge", "--no-ff", "old-side", "-m", "Old merge"])
    try repo.run(["branch", "old-release"])
    for index in 0..<4 {
      try write("recent", "\(index)\n")
      try commitAll("Recent \(index)")
    }
    var filter = LogFilter()
    filter.limit = 2
    let recent = try repo.snapshot(filter: filter)
    XCTAssertEqual(recent.history.count, 2)
    XCTAssertEqual(recent.graphAncestry.count, 7)
    filter.branch = "old-release"
    filter.limit = 20
    var commands: [String] = []
    repo.onCommand = { command, _, _ in commands.append(command) }
    let old = try repo.filteredSnapshot(from: recent, filter: filter)
    repo.onCommand = nil
    XCTAssertTrue(Set(old.commits.map(\.hash)).isDisjoint(with: recent.history.map(\.hash)))
    XCTAssertEqual(old.graphAncestry, recent.graphAncestry)
    XCTAssertFalse(commands.contains { $0.contains("rev-list") })
    let heads = [try repo.resolve("main"), try repo.resolve("old-release")]
    let rows = CommitGraph.layout(old.commits, topology: old.graphAncestry, heads: heads)
    XCTAssertEqual(rows.map(\.lane), [0, 1, 0])
    XCTAssertEqual(rows[0].color, rows[2].color)
    XCTAssertNotEqual(rows[0].color, rows[1].color)
    XCTAssertEqual(Set(rows[0].edges.map(\.color)), Set(rows.prefix(2).map(\.color)))
    let direct = try repo.snapshot(filter: filter)
    XCTAssertEqual(direct.graphAncestry, old.graphAncestry)
    XCTAssertEqual(CommitGraph.layout(direct.commits, topology: direct.graphAncestry, heads: heads).map(\.lane), rows.map(\.lane))
  }
  func testRebaseWorktreeAndAnnotatedTag() throws {
    try write("base", "base")
    try commitAll("Initial")
    try repo.createBranch("feature")
    try write("feature", "feature")
    try commitAll("Feature")
    try repo.run(["switch", "main"])
    try write("main", "main")
    try commitAll("Main")
    try repo.run(["switch", "feature"])
    try repo.run(["rebase", "main"])
    XCTAssertEqual(try repo.log(LogFilter()).first?.subject, "Feature")
    try repo.run(["tag", "-a", "-m", "Release", "--", "v1", "HEAD"])
    XCTAssertEqual(try repo.resolve("v1"), try repo.resolve("HEAD"))
    let worktree = directory.appendingPathComponent("worktree")
    try repo.run(["worktree", "add", "-b", "worktree-test", worktree.path, "HEAD"])
    let other = try GitRepository(url: worktree)
    XCTAssertEqual(try other.snapshot().currentBranch, "worktree-test")
    try repo.run(["worktree", "remove", worktree.path])
  }
  func testCherryPickRevertAndReset() throws {
    try write("a", "base\n")
    try commitAll("Initial")
    let initial = try repo.resolve("HEAD")
    try repo.createBranch("feature")
    try write("b", "feature\n")
    try commitAll("Feature")
    let feature = try repo.resolve("HEAD")
    try repo.run(["switch", "main"])
    try repo.run(["cherry-pick", feature])
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("b").path))
    try repo.run(["revert", "--no-edit", "HEAD"])
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("b").path))
    try repo.run(["reset", "--soft", initial])
    XCTAssertEqual(try repo.resolve("HEAD"), initial)
  }
  func testDiscardAndUnstage() throws {
    try write("a", "base\n")
    try commitAll("Initial")
    try write("a", "changed\n")
    try repo.stage(repo.status())
    try repo.unstage(repo.status())
    XCTAssertFalse(try repo.status()[0].isStaged)
    try repo.discard(repo.status())
    XCTAssertTrue(try repo.status().isEmpty)
    try write("new", "new")
    XCTAssertThrowsError(try repo.discard(repo.status()))
  }
}
final class DiffAndGraphTests {
  func testLineAlignmentAndNumbers() {
    let diff = TextDiff(
      before: Data("one\ntwo\nthree\n".utf8), after: Data("one\nchanged\nextra\nthree\n".utf8))
    XCTAssertEqual(diff.rows.count, 4)
    XCTAssertEqual(diff.rows[1].kind, .modified)
    XCTAssertEqual(diff.rows[2].kind, .added)
    XCTAssertEqual(diff.rows.last?.leftNumber, 3)
    XCTAssertEqual(diff.rows.last?.rightNumber, 4)
    XCTAssertEqual(diff.changes, [1])
  }
  func testDeletionAndEmptyFiles() {
    XCTAssertEqual(TextDiff(before: Data("a\n".utf8), after: Data()).rows[0].kind, .removed)
    XCTAssertEqual(TextDiff(before: Data(), after: Data("a\n".utf8)).rows[0].kind, .added)
    XCTAssertTrue(TextDiff(before: Data(), after: Data()).identical)
  }
  func testBinaryWhitespaceAndFinalNewline() {
    XCTAssertTrue(TextDiff(before: Data([0, 1]), after: Data()).binary)
    XCTAssertEqual(
      TextDiff(before: Data(" a \n".utf8), after: Data("a\n".utf8), ignoreWhitespace: true).changes
        .count, 0)
    XCTAssertFalse(TextDiff(before: Data("a".utf8), after: Data("a\n".utf8)).changes.isEmpty)
    XCTAssertTrue(TextDiff(before: Data(repeating: 65, count: 2_000_001), after: Data()).tooLarge)
  }
  func testMergeGraphLanesAndConvergence() {
    let commits = [
      Commit(hash: "m", parents: ["a", "b"], author: "T", subject: "Merge"),
      Commit(hash: "a", parents: ["r"], author: "T", subject: "A"),
      Commit(hash: "b", parents: ["r"], author: "T", subject: "B"),
      Commit(hash: "r", parents: [], author: "T", subject: "Root"),
    ]
    let rows = CommitGraph.layout(commits)
    XCTAssertTrue(rows[0].isMerge)
    XCTAssertEqual(rows[0].edges.count, 2)
    XCTAssertEqual(rows[1].lane, 0)
    XCTAssertEqual(rows[2].lane, 1)
    XCTAssertEqual(rows[3].lane, 0)
    XCTAssertEqual(rows[2].edges.last?.to, 0)
  }
  func testFilteredGraphProjectsHiddenAncestors() {
    let source = [
      Commit(hash: "a", parents: ["hidden"], author: "T", subject: "A"),
      Commit(hash: "hidden", parents: ["b"], author: "T", subject: "Hidden"),
      Commit(hash: "b", parents: [], author: "T", subject: "B"),
    ]
    let rows = CommitGraph.layout([source[0], source[2]], ancestry: source)
    XCTAssertEqual(rows[0].edges.first?.to, 0)
    XCTAssertTrue(rows[1].incoming)
    XCTAssertEqual(rows[1].lane, 0)
    let disconnected = CommitGraph.layout([source[0], source[2]])
    XCTAssertFalse(disconnected[1].incoming)
    XCTAssertEqual(disconnected[1].lane, 0)
  }

  func testGraphProjectionAcrossHiddenMergeAndOldBoundary() {
    let commits = [
      Commit(hash: "tip", parents: ["hidden-a", "hidden-b", "old-0"], author: "T", subject: "Merge"),
      Commit(hash: "middle", parents: ["old-0"], author: "T", subject: "Middle"),
      Commit(hash: "root", parents: [], author: "T", subject: "Root"),
    ]
    var topology = [
      CommitAncestry(hash: "tip", parents: commits[0].parents),
      CommitAncestry(hash: "hidden-a", parents: ["middle", "root"]),
      CommitAncestry(hash: "hidden-b", parents: ["root", "middle"]),
      CommitAncestry(hash: "middle", parents: ["old-0"]),
      CommitAncestry(hash: "root", parents: []),
    ]
    // The old tail contributes ancestry ranks but no visible edge. Hidden
    // merges must retain first-parent order and deduplicate their destinations.
    for index in 0..<12_000 {
      topology.append(CommitAncestry(hash: "old-\(index)",
        parents: index == 11_999 ? [] : ["old-\(index + 1)"]))
    }
    for source in [topology, topology.reversed().map { $0 }] {
      let rows = CommitGraph.layout(commits, topology: source, heads: ["tip"])
      XCTAssertEqual(rows.map(\.lane), [0, 0, 0])
      // The root still reserves space for the incoming diagonal at its
      // top boundary, so per-row subject text cannot cover the connection.
      XCTAssertEqual(rows.map(\.laneCount), [2, 2, 2])
      XCTAssertEqual(rows.map(\.color), [0, 0, 1])
      XCTAssertEqual(rows.map(\.incoming), [false, true, true])
      XCTAssertTrue(rows[0].isMerge)
      XCTAssertEqual(rows[0].edges.map(\.from), [0, 0])
      XCTAssertEqual(rows[0].edges.map(\.to), [0, 1])
      XCTAssertEqual(rows[0].edges.map(\.color), [0, 1])
      XCTAssertEqual(rows[1].edges.map(\.from), [1])
      XCTAssertEqual(rows[1].edges.map(\.to), [0])
      XCTAssertEqual(rows[1].edges.map(\.color), [1])
      XCTAssertTrue(rows[2].edges.isEmpty)
    }
  }

  func testGraphConnectionsMeetCommitCenters() {
    // A short merged branch, as in new-api: the side commit is immediately
    // below the merge and converges on the main lane at the common ancestor.
    let commits = [
      Commit(hash: "m", parents: ["a", "b"], author: "T", subject: "Merge"),
      Commit(hash: "b", parents: ["a"], author: "T", subject: "Side"),
      Commit(hash: "a", parents: ["r"], author: "T", subject: "Main"),
      Commit(hash: "r", parents: [], author: "T", subject: "Root"),
    ]
    let rows = CommitGraph.layout(commits)
    XCTAssertEqual(rows[1].lane, 1)
    let departure = rows[0].segments.first { $0.toY == 0 && $0.toLane == 0.5 }
    XCTAssertEqual(departure?.fromLane, 0)
    XCTAssertEqual(departure?.fromY, 0.5)
    let arrival = rows[1].segments.first { $0.fromY == 1 && $0.toLane == 1 }
    XCTAssertEqual(arrival?.fromLane, 0.5)
    XCTAssertEqual(arrival?.toY, 0.5)
    let convergence = rows[2].segments.first { $0.fromY == 1 && $0.fromLane == 0.5 }
    XCTAssertEqual(convergence?.toLane, 0)
    XCTAssertEqual(convergence?.toY, 0.5)

    for index in 1..<rows.count {
      let previous = rows[index - 1].segments.filter { $0.toY == 0 }
      let incoming = rows[index].segments.filter { $0.fromY == 1 }
      XCTAssertEqual(previous.count, incoming.count)
      for (outgoing, incoming) in zip(previous, incoming) {
        XCTAssertEqual(outgoing.toLane, incoming.fromLane)
        XCTAssertEqual(outgoing.color, incoming.color)
      }
      if rows[index].incoming {
        XCTAssertTrue(incoming.contains { $0.toLane == Double(rows[index].lane) && $0.toY == 0.5 })
      }
    }
    // Projecting away a side commit still meets the visible ancestor's center.
    let filtered = CommitGraph.layout([commits[0], commits[2], commits[3]], ancestry: commits)
    XCTAssertTrue(filtered[1].segments.contains { $0.fromY == 1 && $0.toLane == Double(filtered[1].lane) && $0.toY == 0.5 })
  }

  func testGraphOldNestedMergesAndIncompleteCache() {
    // The reported origin/cloud topology. The current main tip is newer than
    // the visible rows but determines the left-hand track at the nested merge.
    let links: [(String, [String])] = [
      ("m1", ["m2", "s1"]), ("s1", ["s2"]),
      ("m2", ["m3", "s2"]), ("s2", ["s3"]),
      ("m3", ["m4", "s3"]), ("s3", ["m4"]),
      ("m4", ["m5", "master1"]), ("master1", ["master2", "side1"]),
      ("side1", ["side2"]), ("m5", ["base", "master2"]),
      ("master2", ["base", "side2"]), ("side2", ["base"]), ("base", []),
    ]
    let commits = links.map { Commit(hash: $0.0, parents: $0.1, author: "T", subject: "") }
    let topology = [CommitAncestry(hash: "tip", parents: ["master1"])]
      + links.map { CommitAncestry(hash: $0.0, parents: $0.1) }
    let rows = CommitGraph.layout(commits, topology: topology, heads: ["tip", "m1"])
    XCTAssertEqual(Array(rows.prefix(12).map(\.lane)), [0, 1, 0, 1, 0, 1, 0, 0, 1, 2, 0, 1])
    XCTAssertEqual(rows[0].color, rows[6].color)
    XCTAssertEqual(rows[7].color, rows[10].color)
    XCTAssertNotEqual(rows[6].color, rows[7].color)
    XCTAssertEqual(Set([rows[1].color, rows[3].color, rows[5].color]).count, 3)
    for index in [0, 2, 4] {
      XCTAssertTrue(rows[index].edges.contains { $0.from == 0 && $0.to == 0 && $0.color == rows[index].color })
      XCTAssertTrue(rows[index].edges.contains { $0.to == 1 && $0.color == rows[index + 1].color })
    }
    // Even callers with an incomplete cache must rank all visible commits.
    // The missing tip's context is unavailable, but simple merge tracks and
    // distinct side colors must remain intact instead of turning into zigzags.
    for cache in [Array(topology.prefix(1)), Array(topology.suffix(2))] {
      let fallback = CommitGraph.layout(commits, topology: cache, heads: ["m1"])
      XCTAssertEqual(Array(fallback.prefix(7).map(\.lane)), [0, 1, 0, 1, 0, 1, 0])
      XCTAssertTrue([1, 3, 5].allSatisfy { fallback[$0].color != fallback[0].color })
    }
    // Hiding intermediate main-line commits still projects the same ancestry.
    let filtered = CommitGraph.layout([commits[0], commits[6], commits[7], commits[10], commits[12]], topology: topology, heads: ["tip", "m1"])
    XCTAssertEqual(filtered.map(\.color), [rows[0].color, rows[6].color, rows[7].color, rows[10].color, rows[12].color])
    XCTAssertTrue(filtered.dropFirst().allSatisfy(\.incoming))
  }

  func testGraphBranchColorsFollowConnections() {
    // Two independently headed branches share main's root, like the reported
    // dependabot commits. Their connections must not inherit the root's color.
    let commits = [
      Commit(hash: "main", parents: ["root"], author: "T", subject: "Main"),
      Commit(hash: "side-a", parents: ["side-a-old"], author: "T", subject: "Side A"),
      Commit(hash: "side-b", parents: ["root"], author: "T", subject: "Side B"),
      Commit(hash: "side-a-old", parents: ["root"], author: "T", subject: "Side A old"),
      Commit(hash: "root", parents: [], author: "T", subject: "Root"),
    ]
    let heads = ["main", "side-a", "side-b"]
    let rows = CommitGraph.layout(commits, heads: heads)
    XCTAssertEqual(Set(rows.prefix(3).map(\.color)).count, 3)
    XCTAssertEqual(rows[1].color, rows[3].color)
    for origin in 0..<4 {
      let destination = origin == 1 ? 3 : 4
      var lane = rows[origin].lane
      for row in origin..<destination {
        let connection = rows[row].edges.first { $0.from == lane }
        XCTAssertEqual(connection?.color, rows[origin].color)
        lane = connection?.to ?? -1
      }
      XCTAssertEqual(lane, rows[destination].lane)
    }
    // Filtering out intermediate commits preserves the branch color through
    // projected ancestry and on the terminal connection to the shared root.
    let visible = [commits[0], commits[1], commits[2], commits[4]]
    let filtered = CommitGraph.layout(visible, ancestry: commits, heads: heads)
    XCTAssertEqual(filtered.map(\.color), [rows[0].color, rows[1].color, rows[2].color, rows[4].color])
    XCTAssertEqual(Set(filtered.last!.incomingEdges.map(\.color)), Set(rows.prefix(3).map(\.color)))
    for index in 1..<rows.count {
      XCTAssertEqual(rows[index].incomingEdges.map(\.color), rows[index - 1].edges.map(\.color))
    }
    let merge = [
      Commit(hash: "merge", parents: ["main", "side-a"], author: "T", subject: "Merge"),
    ] + commits
    let merged = CommitGraph.layout(merge, heads: ["merge"])
    XCTAssertEqual(merged[0].color, merged[1].color)
    XCTAssertEqual(Set(merged[0].edges.map(\.color)), Set([merged[1].color, merged[2].color]))
    XCTAssertTrue(merged[2].incomingEdges.contains { $0.to == merged[2].lane && $0.color == merged[2].color })
  }

  func testGraphLongEdgesFoldAndReappear() {
    let commits = [Commit(hash: "merge", parents: ["main1", "side"], author: "T", subject: "Merge")]
      + (1...38).map { Commit(hash: "main\($0)", parents: [$0 == 38 ? "root" : "main\($0 + 1)"], author: "T", subject: "Main") }
      + [Commit(hash: "side", parents: ["root"], author: "T", subject: "Side"),
         Commit(hash: "root", parents: [], author: "T", subject: "Root")]
    let compact = CommitGraph.layout(commits)
    let expanded = CommitGraph.layout(commits, showLongEdges: true)
    for row in compact + expanded {
      XCTAssertTrue(row.segments.allSatisfy { max($0.fromLane, $0.toLane) < Double(row.laneCount) })
      XCTAssertTrue(row.arrows.allSatisfy { $0.lane < row.laneCount })
    }
    XCTAssertEqual(compact.map(\.color), expanded.map(\.color))
    XCTAssertEqual(compact[1].arrows.count, 1)
    XCTAssertTrue(compact[1].arrows[0].pointsDown)
    XCTAssertEqual(compact[1].arrows[0].color, compact[39].color)
    XCTAssertTrue(compact[2..<37].allSatisfy { $0.laneCount == 1 && $0.arrows.isEmpty })
    XCTAssertEqual(compact[38].arrows.count, 1)
    XCTAssertFalse(compact[38].arrows[0].pointsDown)
    XCTAssertEqual(compact[38].arrows[0].color, compact[39].color)
    XCTAssertTrue(compact[39].incoming)
    XCTAssertTrue(expanded.allSatisfy { $0.arrows.isEmpty })
    XCTAssertTrue(expanded[2..<38].allSatisfy { $0.laneCount == 2 })
    // The threshold is measured in displayed rows after filtering.
    let filtered = CommitGraph.layout([commits[0], commits[1], commits[39], commits[40]], ancestry: commits)
    XCTAssertTrue(filtered.allSatisfy { $0.arrows.isEmpty })
    XCTAssertTrue(filtered[2].incoming)
    for distance in [29, 30] {
      let visible = [commits[0]] + Array(commits[1..<distance]) + Array(commits[39...])
      let rows = CommitGraph.layout(visible, ancestry: commits)
      XCTAssertEqual(rows[1].arrows.isEmpty, distance == 29)
    }
    let page = CommitGraph.layout([Commit(hash: "tip", parents: ["unloaded"], author: "T", subject: "Tip")])
    XCTAssertEqual(page[0].arrows.count, 1)
    XCTAssertTrue(page[0].arrows[0].pointsDown)
    XCTAssertTrue(CommitGraph.layout([commits.last!])[0].arrows.isEmpty)
  }

  func testGraphBranchOrderAndDisconnectedHeads() {
    // Same topology and branch-tip precedence as the reported new-api region.
    let commits = [
      Commit(hash: "merge-limits", parents: ["merge-privacy", "limits-1"], author: "T", subject: ""),
      Commit(hash: "limits-1", parents: ["limits-2"], author: "T", subject: ""),
      Commit(hash: "limits-2", parents: ["merge-privacy"], author: "T", subject: ""),
      Commit(hash: "merge-privacy", parents: ["merge-profile", "privacy"], author: "T", subject: ""),
      Commit(hash: "privacy", parents: ["merge-profile"], author: "T", subject: ""),
      Commit(hash: "merge-profile", parents: ["merge-channel", "profile"], author: "T", subject: ""),
      Commit(hash: "profile", parents: ["merge-channel"], author: "T", subject: ""),
      Commit(hash: "merge-channel", parents: ["base", "channel"], author: "T", subject: ""),
      Commit(hash: "channel", parents: ["base"], author: "T", subject: ""),
      Commit(hash: "other-head", parents: ["root"], author: "T", subject: ""),
      Commit(hash: "base", parents: ["root"], author: "T", subject: ""),
      Commit(hash: "root", parents: [], author: "T", subject: ""),
    ]
    let heads = ["root", "other-head", "privacy", "limits-1", "profile", "channel", "merge-limits"]
    let rows = CommitGraph.layout(commits, heads: heads)
    XCTAssertEqual(Array(rows.prefix(9).map(\.lane)), [0, 0, 0, 0, 0, 0, 1, 0, 1])
    XCTAssertFalse(rows[9].incoming)
    XCTAssertEqual(rows[9].lane, 0)
    let filtered = CommitGraph.layout(commits.filter { $0.hash != "other-head" }, ancestry: commits, heads: heads)
    XCTAssertEqual(Array(filtered.prefix(9).map(\.lane)), Array(rows.prefix(9).map(\.lane)))
    XCTAssertTrue(CommitGraph.recommendedLaneCount(rows) >= 2)
    XCTAssertTrue(rows.flatMap(\.edges).allSatisfy { $0.from >= 0 && $0.to >= 0 })
  }

}
