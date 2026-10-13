import Foundation
import GitDeskCore

extension GitRepositoryTests {
  func testSearchBeyondDisplayLimit() throws {
    // Import a real history longer than the default 2,000 visible commits.
    var stream = ""
    for index in 0..<2005 {
      let message: String
      switch index {
      case 0: message = "AncientNeedle common"
      case 1: message = "Old body common\n\nBodyOnlyNeedle 中文 Café"
      case 2: message = "Regex123 common"
      default: message = "ordinary \(index) common"
      }
      let author = index == 0 ? "Ancient Author" : "Recent Author"
      stream += "commit refs/heads/main\ncommitter \(author) <test@example.test> \(1700000000 + index) +0000\ndata \(message.utf8.count)\n\(message)\n"
      stream += "M 100644 inline \(index == 0 ? "target.txt" : "other.txt")\ndata \(String(index).utf8.count)\n\(index)\n\n"
    }
    let input = directory.appendingPathComponent(".git/search-import")
    try Data(stream.utf8).write(to: input)
    let handle = try FileHandle(forReadingFrom: input)
    defer { try? handle.close() }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    task.arguments = ["fast-import", "--quiet"]
    task.currentDirectoryURL = directory
    task.standardInput = handle
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try task.run(); task.waitUntilExit()
    XCTAssertEqual(task.terminationStatus, 0)
    try repo.run(["reset", "--hard", "HEAD"])
    let oldest = try repo.resolve("HEAD~2004")
    XCTAssertEqual(try repo.log().count, 2000)
    XCTAssertFalse(try repo.log().contains { $0.hash == oldest })
    var filter = LogFilter()
    filter.text = "ancientneedle"
    XCTAssertEqual(try repo.log(filter).map(\.hash), [oldest])
    filter.matchCase = true
    XCTAssertTrue(try repo.log(filter).isEmpty)
    filter.text = "AncientNeedle"
    XCTAssertEqual(try repo.log(filter).map(\.hash), [oldest])
    filter.text = String(oldest.prefix(12))
    XCTAssertEqual(try repo.log(filter).map(\.hash), [oldest])
    filter.text = "BodyOnlyNeedle"
    XCTAssertEqual(try repo.log(filter).first?.subject, "Old body common")
    filter.text = "中文 café"; filter.matchCase = false
    XCTAssertEqual(try repo.log(filter).first?.subject, "Old body common")
    filter.text = "Regex\\d+"; filter.regex = true
    XCTAssertEqual(try repo.log(filter).first?.subject, "Regex123 common")
    filter.text = "["
    XCTAssertThrowsError(try repo.log(filter))

    filter = LogFilter(); filter.text = "AncientNeedle"; filter.author = "Ancient Author"
    filter.path = "target.txt"; filter.branch = "main"; filter.firstParent = true
    XCTAssertEqual(try repo.log(filter).map(\.hash), [oldest])
    filter.path = "other.txt"
    XCTAssertTrue(try repo.log(filter).isEmpty)
    filter.path = nil; filter.author = "Recent Author"
    XCTAssertTrue(try repo.log(filter).isEmpty)
    filter.author = nil; filter.since = "2023-11-14T22:13:21Z"
    XCTAssertTrue(try repo.log(filter).isEmpty)
    filter.since = nil; filter.until = "2023-11-14T22:13:21Z"
    XCTAssertEqual(try repo.log(filter).map(\.hash), [oldest])
    filter = LogFilter(); filter.limit = 2; filter.text = "common"
    XCTAssertEqual(try repo.log(filter).map(\.subject), ["ordinary 2004 common", "ordinary 2003 common"])
    filter.text = "missing keyword"
    XCTAssertTrue(try repo.log(filter).isEmpty)
    filter.limit = 0
    XCTAssertTrue(try repo.log(filter).isEmpty)
  }
}
