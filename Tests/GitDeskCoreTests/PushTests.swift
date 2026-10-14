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

extension GitRepositoryTests {
  func testBatchBranchUpdateAndDelete() throws {
    try write("file", "initial\n")
    try commitAll("Initial")
    let main = try repo.resolve("HEAD")
    let bare = directory.appendingPathComponent("remote.git")
    try repo.run(["init", "--bare", bare.path])
    try repo.run(["remote", "add", "origin", bare.path])
    for name in ["alpha", "beta"] {
      try repo.run(["branch", name])
      try repo.run(["push", "-u", "origin", name])
    }
    let writerPath = directory.appendingPathComponent("writer")
    try repo.run(["clone", bare.path, writerPath.path])
    let writer = GitRepository(directory: writerPath)
    try writer.run(["config", "user.name", "Branch Test"])
    try writer.run(["config", "user.email", "branches@example.test"])
    try writer.run(["config", "commit.gpgsign", "false"])
    for name in ["alpha", "beta"] {
      try writer.run(["switch", name])
      try Data("remote \(name)\n".utf8).write(to: writerPath.appendingPathComponent("remote-" + name))
      try writer.run(["add", "--", "remote-" + name])
      try writer.run(["commit", "-m", "Remote " + name])
      try writer.run(["push", "origin", name])
    }
    try write("file", "staged draft\n")
    try repo.run(["add", "--", "file"])
    let indexBefore = try repo.run(["diff", "--cached"])
    let selected = try repo.branches().filter { ["alpha", "beta"].contains($0.name) }
    try repo.updateBranches(selected)
    XCTAssertEqual(try repo.resolve("HEAD"), main)
    XCTAssertEqual(try repo.run(["diff", "--cached"]), indexBefore)
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("file"), encoding: .utf8), "staged draft\n")
    XCTAssertEqual(try repo.resolve("beta"), try writer.resolve("beta"))
    XCTAssertEqual(try repo.resolve("alpha"), try writer.resolve("alpha"))
    // Updating a current branch performs the configured merge-style update.
    try repo.run(["branch", "--set-upstream-to=origin/alpha", "main"])
    try repo.updateBranches(try repo.branches().filter { $0.current })
    XCTAssertEqual(try repo.resolve("HEAD"), try writer.resolve("alpha"))
    XCTAssertEqual(try repo.run(["diff", "--cached"]), indexBefore)
    // Non-current divergent branches must be refused, as IDEA's fetch refspec
    // update does; they must never acquire an unexpected merge commit.
    try repo.run(["switch", "alpha"])
    try write("local-alpha", "local change\n")
    try repo.run(["add", "--", "local-alpha"])
    try repo.run(["commit", "-m", "Divergent alpha"])
    let oldAlpha = try repo.resolve("alpha")
    try repo.run(["switch", "main"])
    try writer.run(["switch", "alpha"])
    try Data("remote advanced\n".utf8).write(to: writerPath.appendingPathComponent("remote-alpha"))
    try writer.run(["add", "--", "remote-alpha"])
    try writer.run(["commit", "-m", "Remote alpha advanced"])
    try writer.run(["push", "origin", "alpha"])
    XCTAssertThrowsError(try repo.updateBranches(selected))
    XCTAssertEqual(try repo.resolve("alpha"), oldAlpha)
    XCTAssertEqual(try repo.run(["worktree", "list", "--porcelain"]).components(separatedBy: "worktree ").count, 2)
    for name in ["delete-one", "delete-two", "keep"] { try repo.run(["branch", name, "main"]) }
    XCTAssertThrowsError(try repo.updateBranches(try repo.branches().filter { $0.name == "keep" }))
    let candidates = try repo.branches().filter { $0.name.hasPrefix("delete-") }
    try repo.deleteBranches(candidates)
    XCTAssertFalse(try repo.branches().contains { $0.name.hasPrefix("delete-") })
    XCTAssertThrowsError(try repo.deleteBranches(try repo.branches().filter { ["main", "keep"].contains($0.name) }))
    XCTAssertTrue(try repo.branches().contains { $0.name == "keep" })
    // A local-only commit absent from its upstream cannot be silently discarded.
    try repo.run(["branch", "unmerged", oldAlpha])
    XCTAssertThrowsError(try repo.deleteBranches(try repo.branches().filter { $0.name == "unmerged" }))
    XCTAssertTrue(try repo.branches().contains { $0.name == "unmerged" })
    let otherWorktree = directory.appendingPathComponent("other-worktree")
    try repo.run(["worktree", "add", otherWorktree.path, "beta"])
    defer { _ = try? repo.run(["worktree", "remove", "--force", otherWorktree.path]) }
    XCTAssertThrowsError(try repo.updateBranches(selected))
  }
}
