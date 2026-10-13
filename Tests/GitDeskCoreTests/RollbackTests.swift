import Foundation
import GitDeskCore

extension GitRepositoryTests {
  func testRollbackPreservesAddedFiles() throws {
    // A first commit does not exist yet. Rollback must still retain new work.
    let newPath = "new [literal]\n中文.txt"
    try write(newPath, "staged content\n")
    try repo.stage(repo.status())
    try write(newPath, "latest unstaged content\n")
    try repo.discard(repo.status())
    XCTAssertEqual(try repo.readWorkingFile(newPath), Data("latest unstaged content\n".utf8))
    XCTAssertTrue(try XCTUnwrap(repo.status().first).isUntracked)
    try commitAll("Initial")

    try write(newPath, "modified existing\n")
    try write("added.txt", "new staged\n")
    try repo.stage(repo.status())
    try write("added.txt", "new working\n")
    try write("unrelated.txt", "keep staged\n")
    try repo.stage(repo.status().filter { $0.path == "unrelated.txt" })
    let unrelatedIndex = try repo.blob(ref: ":", path: "unrelated.txt")
    try repo.discard(repo.status().filter { $0.path != "unrelated.txt" })
    XCTAssertEqual(try repo.readWorkingFile(newPath), Data("latest unstaged content\n".utf8))
    XCTAssertEqual(try repo.readWorkingFile("added.txt"), Data("new working\n".utf8))
    XCTAssertTrue(try XCTUnwrap(repo.status().first { $0.path == "added.txt" }).isUntracked)
    XCTAssertEqual(try repo.blob(ref: ":", path: "unrelated.txt"), unrelatedIndex)
    XCTAssertTrue(try XCTUnwrap(repo.status().first { $0.path == "unrelated.txt" }).isStaged)
    XCTAssertThrowsError(try repo.discard(repo.status().filter { $0.path == "added.txt" }))
  }
}
