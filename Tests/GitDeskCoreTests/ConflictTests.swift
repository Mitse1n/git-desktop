import Foundation
import GitDeskCore

extension GitRepositoryTests {
  func testDeletedAndEmptyConflictSides() throws {
    let path = "file [literal]\n中文.txt"
    try write(path, "base\n")
    try commitAll("Base")
    try repo.run(["switch", "-c", "modified"])
    try write(path, "modified\n")
    try commitAll("Modified")
    try repo.run(["switch", "main"])
    try repo.run(["rm", "--", path])
    try commitAll("Deleted")
    for oursDeleted in [true, false] {
      try repo.run(["switch", oursDeleted ? "main" : "modified"])
      for acceptDeletion in [true, false] {
        XCTAssertThrowsError(try repo.run(["merge", "--no-edit", oursDeleted ? "modified" : "main"]))
        let file = try XCTUnwrap(repo.status().first(where: \.isConflicted))
        let deleted: ConflictSide = oursDeleted ? .ours : .theirs
        let present: ConflictSide = oursDeleted ? .theirs : .ours
        XCTAssertNil(try repo.conflictContents(file, side: deleted))
        XCTAssertEqual(try repo.conflictContents(file, side: present), Data("modified\n".utf8))
        try write("unrelated", "keep staged\n")
        try repo.stage(repo.status().filter { $0.path == "unrelated" })
        try repo.acceptConflicts([file], side: acceptDeletion ? deleted : present)
        XCTAssertFalse(try repo.status().contains(where: \.isConflicted))
        XCTAssertEqual(FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path), !acceptDeletion)
        XCTAssertEqual(try repo.run(["ls-files", "-z", "--", path]).isEmpty, acceptDeletion)
        if !acceptDeletion { XCTAssertEqual(try repo.blob(ref: ":", path: path), Data("modified\n".utf8)) }
        XCTAssertEqual(try repo.blob(ref: ":", path: "unrelated"), Data("keep staged\n".utf8))
        XCTAssertThrowsError(try repo.saveConflict(file, contents: Data("stale\n".utf8)))
        try repo.run(["merge", "--abort"])
        try repo.run(["reset", "--hard", "HEAD"])
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("unrelated"))
      }
    }
    // A present, zero-byte stage is not deletion.
    try repo.run(["switch", "main"])
    try write(path, "shared base\n")
    try commitAll("Shared base for empty conflict")
    try repo.run(["switch", "-c", "empty"])
    try write(path, "")
    try commitAll("Empty added file")
    try repo.run(["switch", "main"])
    try write(path, "other content\n")
    try commitAll("Other added file")
    XCTAssertThrowsError(try repo.run(["merge", "--no-edit", "empty"]))
    let file = try XCTUnwrap(repo.status().first(where: \.isConflicted))
    XCTAssertEqual(try repo.conflictContents(file, side: .theirs), Data())
    try repo.acceptConflicts([file], side: .theirs)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path))
    XCTAssertEqual(try repo.blob(ref: ":", path: path), Data())
    XCTAssertFalse(try repo.status().contains(where: \.isConflicted))
  }
}
