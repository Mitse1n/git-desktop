import Foundation
import GitDeskCore

extension GitRepositoryTests {
  func testProgressiveHistoryPages() throws {
    for index in 0..<12 {
      try write("file.txt", "\(index)\n")
      try commitAll(index % 2 == 0 ? "needle \(index)" : "ordinary \(index)")
    }
    // A merge at the tip has a parent older than the initially visible page.
    try repo.createBranch("side", start: "HEAD~10")
    try write("side.txt", "side branch\n")
    try commitAll("Side commit")
    try repo.run(["switch", "main"])
    try repo.run(["merge", "--no-ff", "--no-edit", "side"])
    var all = LogFilter(); all.limit = 100
    let expected = try repo.log(all)
    var filter = LogFilter(); filter.limit = 4
    let first = try repo.snapshot(filter: filter)
    XCTAssertEqual(first.commits, Array(expected.prefix(4)))
    XCTAssertTrue(first.hasMoreCommits)
    filter.limit = 8
    let second = try repo.filteredSnapshot(from: first, filter: filter)
    XCTAssertEqual(second.commits, Array(expected.prefix(8)))
    XCTAssertEqual(Array(second.commits.prefix(4)), first.commits)
    XCTAssertEqual(Set(second.commits.map(\.hash)).count, second.commits.count)
    XCTAssertEqual(second.graphAncestry, first.graphAncestry)
    XCTAssertTrue(second.hasMoreCommits)
    filter.limit = expected.count
    let exactEnd = try repo.filteredSnapshot(from: second, filter: filter)
    XCTAssertEqual(exactEnd.commits, expected)
    XCTAssertFalse(exactEnd.hasMoreCommits)
    filter.limit = 16
    XCTAssertFalse(try repo.logPage(filter).hasMore)
    XCTAssertEqual(try repo.logPage(filter).commits, expected)

    filter.text = "needle"; filter.limit = 4
    let matches = expected.filter { $0.subject.contains("needle") }
    let searchPage = try repo.logPage(filter)
    XCTAssertEqual(searchPage.commits, Array(matches.prefix(4)))
    XCTAssertTrue(searchPage.hasMore)
    filter.limit = 6
    XCTAssertEqual(try repo.logPage(filter).commits, matches)
    XCTAssertFalse(try repo.logPage(filter).hasMore)
    filter.regex = true; filter.text = "needle \\d+"; filter.limit = 4
    XCTAssertEqual(try repo.logPage(filter).commits, searchPage.commits)
    XCTAssertTrue(try repo.logPage(filter).hasMore)
    filter.path = "missing.txt"
    XCTAssertFalse(try repo.logPage(filter).hasMore)
    XCTAssertTrue(try repo.logPage(filter).commits.isEmpty)
    filter = LogFilter(); filter.limit = 4; filter.branch = expected.last!.hash
    XCTAssertEqual(try repo.logPage(filter).commits.map(\.hash), [expected.last!.hash])
    XCTAssertFalse(try repo.logPage(filter).hasMore)
    var resized = filter; resized.limit = 8
    XCTAssertTrue(filter.hasSameCriteria(as: resized))
    resized.text = "needle"
    XCTAssertFalse(filter.hasSameCriteria(as: resized))
    filter.limit = 0
    XCTAssertThrowsError(try repo.logPage(filter))
    filter.limit = Int.max
    XCTAssertThrowsError(try repo.logPage(filter))
  }
}
