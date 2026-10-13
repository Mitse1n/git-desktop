import Foundation
import GitDeskCore

extension GitRepositoryTests {
  func testPushTargetsAndUpstreamPreservation() throws {
    try write("file", "initial\n")
    try commitAll("Initial")
    for name in ["aaa", "origin"] {
      let bare = directory.appendingPathComponent(name + ".git")
      try repo.run(["init", "--bare", bare.path])
      try repo.run(["remote", "add", name, bare.path])
    }
    XCTAssertEqual(try repo.defaultPushTarget().remote, "origin")
    XCTAssertEqual(try repo.defaultPushTarget().branch, "main")
    try repo.push(remote: "origin", branch: "review/work")
    func upstream() throws -> String {
      try repo.run(["rev-parse", "--abbrev-ref", "@{upstream}"]).trimmingCharacters(in: .newlines)
    }
    XCTAssertEqual(try upstream(), "origin/review/work")
    XCTAssertEqual(try repo.defaultPushTarget().remote, "origin")
    XCTAssertEqual(try repo.defaultPushTarget().branch, "review/work")
    // A deliberate one-off destination must not replace existing tracking either.
    try repo.push(remote: "aaa", branch: "one-off")
    XCTAssertEqual(try upstream(), "origin/review/work")
    XCTAssertTrue(try repo.run(["ls-remote", "aaa", "refs/heads/one-off"]).contains("refs/heads/one-off"))
    XCTAssertTrue(try repo.run(["ls-remote", "aaa", "refs/heads/main"]).isEmpty)
    try repo.push(remote: "origin", branch: "review/work")
    XCTAssertEqual(try upstream(), "origin/review/work")

    try repo.run(["config", "remote.origin.push", "refs/heads/*:refs/heads/published/*"])
    XCTAssertEqual(try repo.defaultPushTarget().branch, "published/main")
    try repo.run(["config", "--add", "remote.origin.push", "main:refs/for/review"])
    XCTAssertEqual(try repo.defaultPushTarget().destination, "refs/for/review")
    try repo.run(["config", "--unset-all", "remote.origin.push"])
    try repo.run(["config", "remote.origin.push", "main:refs/remotes/origin/mapped"])
    XCTAssertEqual(try repo.defaultPushTarget().branch, "mapped")
    try repo.run(["config", "remote.origin.push", "main:refs/for/review"])
    XCTAssertEqual(try repo.defaultPushTarget().destination, "refs/for/review")
    try repo.run(["config", "--unset", "remote.origin.push"])
    try repo.run(["branch", "--unset-upstream"])
    // Existing destination branches are not automatically made upstreams by IDEA.
    try repo.push(remote: "origin", branch: "review/work")
    XCTAssertTrue(try repo.run(["config", "--get", "branch.main.remote"], allowFailure: true).isEmpty)
    XCTAssertThrowsError(try repo.push(remote: "origin", branch: "invalid name"))
    XCTAssertThrowsError(try repo.push(remote: "missing", branch: "main"))
  }
}
