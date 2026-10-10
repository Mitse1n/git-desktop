import Foundation
import GitDeskCore

extension GitRepositoryTests {
  func testUndoAndRewordPreserveLocalChanges() throws {
    try write("a", "base")
    try write("other", "old")
    try commitAll("Initial")
    let initial = try repo.resolve("HEAD")
    try write("a", "committed")
    try commitAll("Second")
    let second = try repo.resolve("HEAD")
    try write("other", "staged")
    try repo.run(["add", "other"])
    try write("other", "working")
    let index = try repo.runData(["ls-files", "--stage", "-z"])
    let author = try repo.commit(at: second).author
    try repo.editHeadMessage("Renamed 'commit'\n\n中文 body $(touch nope)", expectedHead: second)
    let amended = try repo.commit(at: "HEAD")
    XCTAssertEqual(amended.author, author)
    XCTAssertEqual(amended.body, "中文 body $(touch nope)")
    XCTAssertEqual(try repo.blob(ref: "HEAD", path: "other"), Data("old".utf8))
    XCTAssertEqual(try repo.runData(["ls-files", "--stage", "-z"]), index)
    XCTAssertEqual(try repo.readWorkingFile("other"), Data("working".utf8))
    XCTAssertThrowsError(try repo.undoCommit(second))
    try repo.undoCommit(amended.hash)
    XCTAssertEqual(try repo.resolve("HEAD"), initial)
    XCTAssertEqual(try repo.runData(["ls-files", "--stage", "-z"]), index)
    XCTAssertEqual(try repo.readWorkingFile("a"), Data("committed".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("nope").path))
  }
  func testUndoRootAndHistoryGuards() throws {
    try write("a", "initial")
    try commitAll("Initial")
    let head = try repo.resolve("HEAD")
    try repo.run(["update-ref", "refs/remotes/origin/main", head])
    XCTAssertEqual(try repo.historyEditContext(from: head).publishedRefs, ["origin/main"])
    XCTAssertThrowsError(try repo.undoCommit(head, expectedBranch: "different"))
    try repo.run(["switch", "--detach", head])
    XCTAssertThrowsError(try repo.undoCommit(head))
    try repo.run(["switch", "main"])
    try repo.undoCommit(head)
    XCTAssertFalse(repo.hasHead)
    XCTAssertEqual(try repo.status().first?.index, "A")
    XCTAssertEqual(try repo.readWorkingFile("a"), Data("initial".utf8))
  }
  func testRevisionTreeAndPatch() throws {
    let names = ["dir/中文.txt", "tab\tfile", "line\nbreak", ":(glob)*", "quote'file"]
    for name in names { try write(name, "old\n") }
    try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link").path,
      withDestinationPath: "dir/中文.txt")
    try Data([0, 1, 2]).write(to: directory.appendingPathComponent("binary"))
    try commitAll("Initial")
    let initial = try repo.resolve("HEAD")
    let files = try repo.revisionFiles(at: initial)
    XCTAssertEqual(Set(files.map(\.path)), Set(names + ["link", "binary"]))
    let link = try XCTUnwrap(files.first { $0.path == "link" })
    XCTAssertEqual(link.mode, "120000")
    XCTAssertEqual(try repo.revisionContents(link), Data("dir/中文.txt".utf8))
    let rootPatch = try repo.patch(for: initial)
    XCTAssertTrue(String(decoding: rootPatch, as: UTF8.self).contains("Subject: [PATCH] Initial"))
    try write(names[0], "new\n")
    try repo.run(["mv", "quote'file", "renamed"])
    try Data([0, 3, 4]).write(to: directory.appendingPathComponent("binary"))
    try commitAll("Update")
    let patch = try repo.patch(for: "HEAD")
    let file = directory.appendingPathComponent("update.patch")
    try patch.write(to: file)
    try repo.run(["reset", "--hard", initial])
    try repo.run(["apply", "--check", file.path])
    try repo.run(["apply", file.path])
    XCTAssertEqual(try repo.readWorkingFile(names[0]), Data("new\n".utf8))
    XCTAssertEqual(try repo.readWorkingFile("binary"), Data([0, 3, 4]))
    let empty = directory.appendingPathComponent("patch-root")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let other = GitRepository(directory: empty)
    try other.run(["init"])
    let rootFile = directory.appendingPathComponent("root.patch")
    try rootPatch.write(to: rootFile)
    try other.run(["apply", rootFile.path])
    XCTAssertEqual(try other.readWorkingFile("link"), Data("dir/中文.txt".utf8))
    try repo.run(["reset", "--hard", initial])
    try write("large", String(repeating: "x", count: 2_000_001))
    try repo.run(["add", "large"])
    try repo.run(["update-index", "--add", "--cacheinfo", "160000", initial, "module"])
    try repo.run(["commit", "-m", "Tree modes"])
    let special = try repo.revisionFiles(at: "HEAD")
    XCTAssertThrowsError(try repo.revisionContents(XCTUnwrap(special.first { $0.path == "large" })))
    XCTAssertThrowsError(try repo.revisionContents(XCTUnwrap(special.first { $0.path == "module" })))
    XCTAssertEqual(try repo.revisionContents(XCTUnwrap(files.first { $0.path == names[0] })), Data("old\n".utf8))
  }
  func historyFixture() throws -> [Commit] {
    try write("base", "base\n")
    try commitAll("Initial")
    for name in ["A", "B", "C", "D"] {
      try write(name, name + "\n")
      try commitAll(name)
    }
    return Array(try repo.log().reversed())
  }
  func testRebaseReorderRewordAndDrop() throws {
    let quoted = directory.appendingPathExtension(" space'quote")
    try FileManager.default.moveItem(at: directory, to: quoted)
    directory = quoted
    repo = GitRepository(directory: directory)
    let commits = try historyFixture()
    let plan = try repo.prepareRebase(from: commits[1].hash)
    var entries = plan.entries
    entries.swapAt(0, 1)
    entries[2].action = .reword
    entries[2].message = "Edited C\n\nBody '中文' $(touch nope)"
    entries[3].action = .drop
    try repo.applyRebase(plan, entries: entries)
    XCTAssertEqual(Array(try repo.log().map(\.subject).reversed()), ["Initial", "B", "A", "Edited C"])
    XCTAssertEqual(try repo.commit(at: "HEAD").body, "Body '中文' $(touch nope)")
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("D").path))
    XCTAssertNil(try repo.activeOperation())
    XCTAssertTrue(try repo.status().isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try repo.gitDirectory().appendingPathComponent("gitdesk-rebase").path))
  }
  func testRebaseSquashFixupAndRoot() throws {
    let commits = try historyFixture()
    let plan = try repo.prepareRebase(from: commits[1].hash)
    var entries = plan.entries
    entries[1].action = .squash
    entries[1].message = "Combined A + B"
    entries[2].action = .fixup
    try repo.applyRebase(plan, entries: entries)
    XCTAssertEqual(Array(try repo.log().map(\.subject).reversed()), ["Initial", "Combined A + B", "D"])
    XCTAssertEqual(try repo.readWorkingFile("C"), Data("C\n".utf8))
    let root = try repo.log().last!.hash
    let rootPlan = try repo.prepareRebase(from: root)
    var rootEntries = rootPlan.entries
    rootEntries[0].action = .reword
    rootEntries[0].message = "New initial"
    try repo.applyRebase(rootPlan, entries: rootEntries)
    XCTAssertEqual(try repo.log().last?.subject, "New initial")
    XCTAssertTrue(try repo.status().isEmpty)
  }
  func testRebaseConflictRecovery() throws {
    try write("a", "base\n")
    try commitAll("Initial")
    try write("a", "one\n")
    try commitAll("One")
    let one = try repo.resolve("HEAD")
    try write("a", "two\n")
    try commitAll("Two")
    let head = try repo.resolve("HEAD")
    let plan = try repo.prepareRebase(from: one)
    var entries = plan.entries
    entries[0].action = .reword
    entries[0].message = "Reword after conflict"
    entries.swapAt(0, 1)
    XCTAssertThrowsError(try repo.applyRebase(plan, entries: entries))
    XCTAssertEqual(try repo.activeOperation(), "rebase")
    try repo.resumeRebase("abort")
    XCTAssertEqual(try repo.resolve("HEAD"), head)
    XCTAssertEqual(try repo.readWorkingFile("a"), Data("two\n".utf8))
    XCTAssertThrowsError(try repo.applyRebase(plan, entries: entries))
    for _ in 0..<5 where (try repo.activeOperation()) == "rebase" {
      if try repo.status().contains(where: \.isConflicted) {
        try write("a", "resolved\n")
        try repo.run(["add", "a"])
      }
      _ = try? repo.resumeRebase("continue")
    }
    XCTAssertNil(try repo.activeOperation())
    XCTAssertEqual(try repo.commit(at: "HEAD").subject, "Reword after conflict")
    try repo.run(["reset", "--hard", head])
    XCTAssertThrowsError(try repo.applyRebase(plan, entries: entries))
    try repo.resumeRebase("skip")
    XCTAssertNil(try repo.activeOperation())
    XCTAssertEqual(try repo.commit(at: "HEAD").subject, "Reword after conflict")
  }
  func testAutomaticSquashDropAllAndStaleSession() throws {
    let commits = try historyFixture()
    let plan = try repo.prepareRebase(from: commits[1].hash)
    var entries = plan.entries
    entries[1].action = .squash
    entries[2].action = .fixup
    let stale = try repo.gitDirectory().appendingPathComponent("gitdesk-rebase")
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    try repo.applyRebase(plan, entries: entries)
    let combined = try repo.log()[1]
    XCTAssertEqual(combined.subject, "A")
    XCTAssertTrue(combined.body.contains("B"))
    XCTAssertFalse(combined.body.contains("C"))
    let dropPlan = try repo.prepareRebase(from: combined.hash)
    var dropped = dropPlan.entries
    for index in dropped.indices { dropped[index].action = .drop }
    try repo.applyRebase(dropPlan, entries: dropped)
    XCTAssertEqual(try repo.log().map(\.subject), ["Initial"])
    XCTAssertTrue(try repo.status().isEmpty)
  }
  func testHistoryPlanValidationAndNavigation() throws {
    let commits = try historyFixture()
    let plan = try repo.prepareRebase(from: commits[1].hash)
    XCTAssertEqual(try repo.children(of: commits[1].hash).map(\.hash), [commits[2].hash])
    try repo.run(["branch", "same-tip"])
    try repo.run(["switch", "same-tip"])
    XCTAssertThrowsError(try repo.applyRebase(plan, entries: plan.entries))
    try repo.run(["switch", "main"])
    var invalid = plan.entries
    invalid[0].action = .squash
    XCTAssertThrowsError(try repo.applyRebase(plan, entries: invalid))
    XCTAssertThrowsError(try repo.applyRebase(plan, entries: [plan.entries[0], plan.entries[0]]))
    try write("dirty", "local")
    XCTAssertThrowsError(try repo.applyRebase(plan, entries: plan.entries))
    try FileManager.default.removeItem(at: directory.appendingPathComponent("dirty"))
    try repo.createBranch("side", start: commits[0].hash)
    try write("side", "side")
    try commitAll("Side")
    try repo.run(["switch", "main"])
    try repo.run(["merge", "--no-edit", "side"])
    XCTAssertThrowsError(try repo.prepareRebase(from: commits[1].hash))
    let merge = try repo.commit(at: "HEAD")
    XCTAssertEqual(merge.parents.count, 2)
    XCTAssertEqual(Set(try repo.children(of: commits[0].hash).map(\.subject)), Set(["A", "Side"]))
    XCTAssertTrue(String(decoding: try repo.patch(for: merge.hash), as: UTF8.self).contains("diff --git"))
  }
}
