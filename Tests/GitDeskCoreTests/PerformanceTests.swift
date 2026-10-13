import Foundation
import GitDeskCore

extension DiffAndGraphTests {
  func testOptimizedDiffMatchesReference() {
    var comparisons = 0
    func verify(_ before: Data, _ after: Data, ignore: Bool) {
      let actual = TextDiff(before: before, after: after, ignoreWhitespace: ignore)
      let expected = ReferenceTextDiff(before: before, after: after, ignoreWhitespace: ignore)
      XCTAssertEqual(actual.binary, expected.binary)
      XCTAssertEqual(actual.tooLarge, expected.tooLarge)
      XCTAssertEqual(actual.identical, expected.identical)
      XCTAssertEqual(actual.changes, expected.changes)
      XCTAssertEqual(actual.rows.map { ReferenceDiffLine(left: $0.left, right: $0.right,
        leftNumber: $0.leftNumber, rightNumber: $0.rightNumber, kind: $0.kind) }, expected.rows)
      comparisons += 1
    }
    var corpus: [[String]] = [[]]
    var level: [[String]] = [[]]
    for _ in 0..<4 {
      level = level.flatMap { prefix in ["a", "b", "中文🙂"].map { prefix + [$0] } }
      corpus += level
    }
    for (i, left) in corpus.enumerated() {
      for (j, right) in corpus.enumerated() {
        let before = Data((left.joined(separator: "\n") + (i % 2 == 0 && !left.isEmpty ? "\n" : "")).utf8)
        let after = Data((right.joined(separator: "\n") + (j % 2 == 0 && !right.isEmpty ? "\n" : "")).utf8)
        for ignore in [false, true] { verify(before, after, ignore: ignore) }
      }
    }
    var seed: UInt64 = 0x12345678
    func random(_ bound: Int) -> Int {
      seed = seed &* 6364136223846793005 &+ 1
      return Int((seed >> 32) % UInt64(bound))
    }
    let words = ["a", " a ", "\tb", "中文🙂", "e\u{301}", "é", "", "same", "unique"]
    for _ in 0..<2000 {
      func text() -> Data {
        let lines = (0..<random(40)).map { _ in words[random(words.count)] }
        return Data((lines.joined(separator: "\n") + (random(2) == 0 ? "\n" : "")).utf8)
      }
      let before = text(), after = text()
      for ignore in [false, true] { verify(before, after, ignore: ignore) }
    }
    for pair in [(Data([0, 1]), Data()), (Data([255]), Data("valid".utf8)),
      (Data(repeating: 65, count: 2_000_001), Data()),
      (Data(String(repeating: "x\n", count: 20001).utf8), Data("y".utf8)),
      (Data("a\r\nb\r\n".utf8), Data("a\nb\n".utf8))] {
      for ignore in [false, true] { verify(pair.0, pair.1, ignore: ignore) }
    }
    print("Exact Diff reference parity: \(comparisons) cases, including duplicate/reordered lines, Unicode, whitespace and limits")
  }
  func testDiffCancellationAndLargeReplacement() {
    let before = Data((0..<10000).map { "old \($0)\n" }.joined().utf8)
    let after = Data((0..<10000).map { "new \($0)\n" }.joined().utf8)
    XCTAssertNil(TextDiff(before: before, after: after, shouldCancel: { true }))
    var checkpoints = 0
    XCTAssertNil(TextDiff(before: before, after: after, shouldCancel: {
      checkpoints += 1; return checkpoints > 3
    }))
    let result = TextDiff(before: before, after: after)
    XCTAssertEqual(result.rows.count, 10000)
    XCTAssertEqual(result.changes, [0])
    XCTAssertTrue(result.rows.enumerated().allSatisfy { i, row in
      row.left == "old \(i)" && row.right == "new \(i)"
        && row.leftNumber == i + 1 && row.rightNumber == i + 1 && row.kind == .modified
    })
  }
}

extension GitRepositoryTests {
  func testAncestryCachePublicationRaces() throws {
    try write("base", "one\n"); try commitAll("one")
    let first = try repo.resolve("HEAD")
    try write("base", "two\n"); try commitAll("two")
    let second = try repo.resolve("HEAD")
    _ = try repo.snapshot()
    try repo.run(["branch", "cache-miss"])
    var injected = false
    repo.onCommand = { command, _, _ in
      if command.hasPrefix("git rev-list"), !injected {
        injected = true
        try! self.repo.run(["update-ref", "refs/custom/aba", first])
        try! self.repo.run(["update-ref", "-d", "refs/custom/aba"])
      }
    }
    _ = try repo.snapshot()
    XCTAssertTrue(injected)
    var commands: [String] = []
    repo.onCommand = { command, _, _ in commands.append(command) }
    _ = try repo.snapshot()
    XCTAssertTrue(commands.contains { $0.hasPrefix("git rev-list") })
    repo.onCommand = nil
    let tree = try repo.run(["rev-parse", "HEAD^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let orphan = try repo.run(["commit-tree", tree, "-m", "racing orphan"]).trimmingCharacters(in: .whitespacesAndNewlines)
    try repo.run(["branch", "another-cache-miss"])
    injected = false
    repo.onCommand = { command, _, _ in
      if command == "git show-ref --head", !injected {
        injected = true
        try! self.repo.run(["update-ref", "refs/heads/main", orphan])
      }
    }
    _ = try repo.snapshot()
    repo.onCommand = nil
    try repo.run(["update-ref", "refs/heads/main", second])
    let actual = try repo.snapshot()
    let fresh = try GitRepository(directory: directory).snapshot()
    XCTAssertEqual(actual, fresh)
    XCTAssertFalse(actual.graphAncestry.contains { $0.hash == orphan })
    // Many-reference repositories use the uncached path. External ref changes
    // must still be observed without carrying forward a prior cached graph.
    for index in 0..<260 { try write(".git/refs/custom/many-\(index)", second + "\n") }
    _ = try repo.snapshot()
    try write(".git/refs/custom/many-0", orphan + "\n")
    XCTAssertEqual(try repo.snapshot(), try GitRepository(directory: directory).snapshot())
    XCTAssertTrue(try repo.snapshot().graphAncestry.contains { $0.hash == orphan })
  }
  func testAncestryCacheInvalidation() throws {
    try write("base", "one\n"); try commitAll("one")
    let first = try repo.resolve("HEAD")
    try write("base", "two\n"); try commitAll("two")
    let second = try repo.resolve("HEAD")
    let original = try repo.snapshot()
    var commands: [String] = []
    repo.onCommand = { command, _, _ in commands.append(command) }
    XCTAssertEqual(try repo.snapshot().graphAncestry, original.graphAncestry)
    repo.onCommand = nil
    XCTAssertFalse(commands.contains { $0.hasPrefix("git rev-list") })
    func matchesUncached() throws {
      let fresh = GitRepository(directory: directory)
      XCTAssertEqual(try repo.snapshot(), try fresh.snapshot())
    }
    try write("untracked", "local\n"); try matchesUncached()
    try repo.run(["branch", "another"]); try matchesUncached()
    try repo.run(["tag", "-a", "-m", "tag", "v1"]); try matchesUncached()
    try repo.run(["checkout", "--detach", first]); try matchesUncached()
    try repo.run(["checkout", "main"]); try matchesUncached()
    let tree = try repo.run(["rev-parse", "HEAD^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let orphan = try repo.run(["commit-tree", tree, "-m", "custom ref"]).trimmingCharacters(in: .whitespacesAndNewlines)
    try repo.run(["update-ref", "refs/custom/test", orphan]); try matchesUncached()
    try repo.run(["update-ref", "-d", "refs/custom/test"]); try matchesUncached()
    try repo.run(["replace", second, orphan]); try matchesUncached()
    try repo.run(["replace", "-d", second]); try matchesUncached()
    try write(".git/shallow", second + "\n"); try matchesUncached()
    XCTAssertEqual(try repo.snapshot().graphAncestry.count, 1)
    try FileManager.default.removeItem(at: directory.appendingPathComponent(".git/shallow"))
    try matchesUncached()
    try write(".git/info/grafts", second + "\n"); try matchesUncached()
    XCTAssertEqual(try repo.snapshot().graphAncestry.count, 1)
    try FileManager.default.removeItem(at: directory.appendingPathComponent(".git/info/grafts"))
    try matchesUncached()
    try write("base", "three\n"); try commitAll("three"); try matchesUncached()
    let worktree = directory.deletingLastPathComponent().appendingPathComponent("gitdesk-cache-linked-" + UUID().uuidString)
    try repo.run(["worktree", "add", "-b", "cache-linked", worktree.path, "HEAD"])
    defer { _ = try? repo.run(["worktree", "remove", "--force", worktree.path]) }
    let linked = GitRepository(directory: worktree)
    let linkedBefore = try linked.snapshot().graphAncestry
    try write(".git/shallow", second + "\n")
    let linkedShallow = try linked.snapshot().graphAncestry
    XCTAssertNotEqual(linkedBefore, linkedShallow)
    XCTAssertEqual(linkedShallow, try GitRepository(directory: worktree).snapshot().graphAncestry)
    try FileManager.default.removeItem(at: directory.appendingPathComponent(".git/shallow"))
    XCTAssertEqual(try linked.snapshot().graphAncestry, linkedBefore)
    try repo.run(["reset", "--hard", first]); try matchesUncached()
  }
}

struct ReferenceDiffLine: Equatable {
  let left: String?
  let right: String?
  let leftNumber: Int?
  let rightNumber: Int?
  let kind: DiffLine.Kind
}

// Frozen pre-optimization implementation: differential oracle for visible row alignment.
struct ReferenceTextDiff {
  let rows: [ReferenceDiffLine]
  let binary: Bool
  let tooLarge: Bool
  let identical: Bool
  var changes: [Int] {
    rows.indices.filter {
      rows[$0].kind != .unchanged && ($0 == 0 || rows[$0 - 1].kind == .unchanged)
    }
  }
  init(before: Data, after: Data, ignoreWhitespace: Bool = false) {
    binary =
      before.contains(0) || after.contains(0) || String(data: before, encoding: .utf8) == nil
      || String(data: after, encoding: .utf8) == nil
    tooLarge = before.count + after.count > 2_000_000
    identical = before == after
    guard !binary, !tooLarge else {
      rows = []
      return
    }
    func lines(_ data: Data) -> [String] {
      guard !data.isEmpty else { return [] }
      var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
      if lines.last == "" { lines.removeLast() }
      return lines
    }
    let a = lines(before)
    let b = lines(after)
    guard a.count + b.count <= 20000 else {
      rows = []
      return
    }
    let normal: (String) -> String = {
      ignoreWhitespace
        ? $0.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined() : $0
    }
    let delta = b.map(normal).difference(from: a.map(normal))
    var removed = Set<Int>()
    var inserted = Set<Int>()
    for change in delta {
      switch change {
      case .remove(let i, _, _): removed.insert(i)
      case .insert(let i, _, _): inserted.insert(i)
      }
    }
    var result: [ReferenceDiffLine] = []
    var i = 0
    var j = 0
    while i < a.count || j < b.count {
      var old: [(Int, String)] = []
      var new: [(Int, String)] = []
      while i < a.count && removed.contains(i) {
        old.append((i + 1, a[i]))
        i += 1
      }
      while j < b.count && inserted.contains(j) {
        new.append((j + 1, b[j]))
        j += 1
      }
      for k in 0..<max(old.count, new.count) {
        let l = k < old.count ? old[k] : nil
        let r = k < new.count ? new[k] : nil
        result.append(
          ReferenceDiffLine(
            left: l?.1, right: r?.1, leftNumber: l?.0, rightNumber: r?.0,
            kind: l == nil ? .added : r == nil ? .removed : .modified))
      }
      if i < a.count && j < b.count {
        result.append(
          ReferenceDiffLine(left: a[i], right: b[j], leftNumber: i + 1, rightNumber: j + 1, kind: .unchanged)
        )
        i += 1
        j += 1
      } else if old.isEmpty && new.isEmpty {
        break
      }
    }
    // Preserve a visible indication when only the final newline changed.
    if result.allSatisfy({ $0.kind == .unchanged }) && before != after && !ignoreWhitespace {
      result.append(
        ReferenceDiffLine(
          left: before.last == 10 ? "" : "No newline at end of file",
          right: after.last == 10 ? "" : "No newline at end of file", leftNumber: nil,
          rightNumber: nil, kind: .modified))
    }
    rows = result
  }
}
