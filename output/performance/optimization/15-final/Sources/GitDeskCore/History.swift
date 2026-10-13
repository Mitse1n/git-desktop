import Foundation

public struct HistoryEditContext {
  public let head: String
  public let branch: String
  public let publishedRefs: [String]
}
public enum RebaseAction: String, CaseIterable {
  case pick, reword, squash, fixup, drop
}
public struct RebaseEntry {
  public let commit: Commit
  public var action: RebaseAction
  public var message: String?
  public init(commit: Commit, action: RebaseAction = .pick, message: String? = nil) {
    self.commit = commit
    self.action = action
    self.message = message
  }
}
public struct RebasePlan {
  public let branch: String
  public let head: String
  public let base: String?
  public let entries: [RebaseEntry]
}
public struct RevisionFile: Equatable {
  public let path: String
  public let object: String
  public let mode: String
  public let kind: String
}

extension GitRepository {
  public func commit(at ref: String) throws -> Commit {
    var filter = LogFilter()
    filter.branch = ref
    filter.limit = 1
    guard let commit = try log(filter).first else { throw GitFailure("Commit not found.") }
    return commit
  }
  public func gitDirectory() throws -> URL {
    URL(fileURLWithPath: try run(["rev-parse", "--absolute-git-dir"])
      .trimmingCharacters(in: .whitespacesAndNewlines))
  }
  public func activeOperation() throws -> String? {
    let directory = try gitDirectory()
    for (file, operation) in [("rebase-merge", "rebase"), ("rebase-apply", "rebase"),
      ("MERGE_HEAD", "merge"), ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert")]
    where FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) {
      return operation
    }
    return nil
  }
  public func historyEditContext(from ref: String, expectedHead: String? = nil,
    expectedBranch: String? = nil, requireClean: Bool = false) throws -> HistoryEditContext
  {
    guard try activeOperation() == nil else {
      throw GitFailure("Finish or abort the current Git operation before editing history.")
    }
    let head = try resolve("HEAD")
    if let expectedHead, head != expectedHead {
      throw GitFailure("HEAD changed. Refresh the history and try again.")
    }
    let branch = try run(["symbolic-ref", "--quiet", "--short", "HEAD"], allowFailure: true)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branch.isEmpty else { throw GitFailure("Checkout a local branch before editing history.") }
    if let expectedBranch, branch != expectedBranch {
      throw GitFailure("The current branch changed. Refresh and try again.")
    }
    let hash = try resolve(ref)
    do { try run(["merge-base", "--is-ancestor", hash, head]) }
    catch { throw GitFailure("Select a commit in the current branch.") }
    if requireClean, !(try status()).isEmpty {
      throw GitFailure("Commit or stash all local changes before rebasing. No changes were made.")
    }
    let refs = try run(["for-each-ref", "--contains=" + hash, "--format=%(refname:short)", "refs/remotes"])
      .split(separator: "\n").map(String.init)
    return HistoryEditContext(head: head, branch: branch, publishedRefs: refs)
  }
  public func undoCommit(_ expectedHead: String, expectedBranch: String? = nil) throws {
    _ = try historyEditContext(from: expectedHead, expectedHead: expectedHead, expectedBranch: expectedBranch)
    let commit = try self.commit(at: expectedHead)
    if let parent = commit.parents.first {
      try run(["reset", "--soft", parent])
    } else {
      // Delete only the verified branch tip; leave index and working files intact.
      let ref = try run(["symbolic-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
      try run(["update-ref", "-d", ref, expectedHead])
    }
  }
  public func editHeadMessage(_ message: String, expectedHead: String, expectedBranch: String? = nil) throws {
    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GitFailure("Commit message cannot be empty.")
    }
    _ = try historyEditContext(from: expectedHead, expectedHead: expectedHead, expectedBranch: expectedBranch)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("gitdesk-message-" + UUID().uuidString)
    try Data(message.utf8).write(to: file, options: .atomic)
    defer { try? FileManager.default.removeItem(at: file) }
    // --only excludes unrelated staged changes from the amended commit.
    try run(["commit", "--amend", "--only", "--allow-empty", "--file", file.path])
  }
  public func children(of ref: String) throws -> [Commit] {
    let hash = try resolve(ref)
    let rows = try run(["rev-list", "--all", "HEAD", "--children"]).split(separator: "\n")
    guard let line = rows.first(where: { $0.split(separator: " ").first == Substring(hash) }) else { return [] }
    return try line.split(separator: " ").dropFirst().map { try commit(at: String($0)) }
  }
  public func patch(for ref: String) throws -> Data {
    let commit = try self.commit(at: ref)
    if commit.parents.count > 1 {
      return try runData(["diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv",
        commit.parents[0], commit.hash])
    }
    return try runData(["format-patch", "--stdout", "--binary", "--full-index", "--no-signature",
      "--no-ext-diff", "--no-textconv", "--root", "-1", commit.hash])
  }
  public func revisionFiles(at ref: String) throws -> [RevisionFile] {
    let hash = try resolve(ref)
    return try runData(["ls-tree", "-r", "-z", "--full-tree", hash]).split(separator: 0).compactMap { record in
      guard let tab = record.firstIndex(of: 9) else { return nil }
      let metadata = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
      guard metadata.count == 3 else { return nil }
      return RevisionFile(path: String(decoding: record[record.index(after: tab)...], as: UTF8.self),
        object: String(metadata[2]), mode: String(metadata[0]), kind: String(metadata[1]))
    }
  }
  public func revisionContents(_ file: RevisionFile, limit: Int = 2_000_000) throws -> Data {
    guard file.kind == "blob" else { throw GitFailure("Submodule at " + file.object + ". Open its repository to browse files.") }
    let size = try run(["cat-file", "-s", file.object]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let bytes = Int(size), bytes <= limit else { throw GitFailure("File exceeds the 2 MB preview limit.") }
    return try runData(["cat-file", "blob", file.object])
  }
  public func prepareRebase(from ref: String) throws -> RebasePlan {
    let context = try historyEditContext(from: ref, requireClean: true)
    let hash = try resolve(ref)
    var filter = LogFilter()
    filter.branch = context.head
    filter.limit = 10001
    let history = try log(filter)
    guard let index = history.firstIndex(where: { $0.hash == hash }), index < 10000 else {
      throw GitFailure("The selected range exceeds the 10,000 commit history editor limit.")
    }
    let commits = Array(history.prefix(index + 1).reversed())
    guard commits.allSatisfy({ $0.parents.count <= 1 }) else {
      throw GitFailure("This range contains merge commits. Choose a linear range after the merge; merge-preserving history editing is not supported.")
    }
    return RebasePlan(branch: context.branch, head: context.head, base: commits.first?.parents.first,
      entries: commits.map { RebaseEntry(commit: $0) })
  }
  public static func validateRebaseEntries(_ entries: [RebaseEntry], plan: RebasePlan) throws {
    let original = Set(plan.entries.map { $0.commit.hash })
    guard entries.count == original.count, Set(entries.map { $0.commit.hash }) == original else {
      throw GitFailure("Every commit must occur exactly once in the plan. Use Drop to remove a commit.")
    }
    var retained = false
    for entry in entries {
      if entry.action == .drop { continue }
      if entry.action == .squash || entry.action == .fixup {
        guard retained else { throw GitFailure("Squash and Fixup require an earlier retained commit.") }
      }
      if entry.action == .reword, (entry.message ?? entry.commit.fullMessage)
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw GitFailure("A reworded commit needs a nonempty message.")
      }
      if let message = entry.message, entry.action == .squash,
        message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw GitFailure("A squash message cannot be empty. Use the automatic combined message instead.")
      }
      retained = true
    }
    guard retained || plan.base != nil else { throw GitFailure("Cannot drop every commit including the repository root.") }
  }
  public func applyRebase(_ plan: RebasePlan, entries: [RebaseEntry]) throws {
    guard let first = plan.entries.first else { throw GitFailure("Empty rebase plan.") }
    let fresh = try prepareRebase(from: first.commit.hash)
    guard fresh.branch == plan.branch, fresh.head == plan.head, fresh.base == plan.base,
      fresh.entries.map({ $0.commit.hash }) == plan.entries.map({ $0.commit.hash }) else {
      throw GitFailure("History changed while the editor was open. Reopen the editor.")
    }
    try Self.validateRebaseEntries(entries, plan: plan)
    let session = try gitDirectory().appendingPathComponent("gitdesk-rebase")
    // An external continue/abort may have completed a previous session.
    if FileManager.default.fileExists(atPath: session.path) {
      try FileManager.default.removeItem(at: session)
    }
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    do {
      var todo: [String] = []
      for (index, entry) in entries.enumerated() {
        todo.append((entry.action == .reword ? "pick" : entry.action.rawValue) + " " + entry.commit.hash)
        if entry.action == .reword || (entry.action == .squash && entry.message != nil) {
          let file = session.appendingPathComponent("message-\(index)")
          try Data((entry.message ?? entry.commit.fullMessage).utf8).write(to: file)
          todo.append("exec /usr/bin/git commit --amend --only --allow-empty --file " + Self.shellQuote(file.path))
        }
      }
      let todoFile = session.appendingPathComponent("todo")
      try Data((todo.joined(separator: "\n") + "\n").utf8).write(to: todoFile)
      let editor = session.appendingPathComponent("editor.sh")
      try Data("#!/bin/sh\nexec /bin/cp \"$GITDESK_REBASE_TODO\" \"$1\"\n".utf8).write(to: editor)
      try run(["-c", "rebase.updateRefs=false", "rebase", "--interactive", "--force-rebase",
        "--keep-empty", "--empty=keep", "--no-autostash", "--no-autosquash", "--reschedule-failed-exec"]
        + (plan.base.map { [$0] } ?? ["--root"]), environment: [
          "GIT_SEQUENCE_EDITOR": "/bin/sh " + Self.shellQuote(editor.path),
          "GITDESK_REBASE_TODO": todoFile.path, "GIT_EDITOR": "true",
        ])
      try FileManager.default.removeItem(at: session)
    } catch {
      // Message files are referenced by the persisted Git todo after a conflict.
      if (try? activeOperation()) != "rebase" { try? FileManager.default.removeItem(at: session) }
      throw error
    }
  }
  public func resumeRebase(_ action: String) throws {
    guard ["continue", "skip", "abort"].contains(action) else { throw GitFailure("Invalid rebase action.") }
    do {
      try run(["rebase", "--" + action], environment: ["GIT_EDITOR": "true"])
      if try activeOperation() != "rebase" {
        let session = try gitDirectory().appendingPathComponent("gitdesk-rebase")
        if FileManager.default.fileExists(atPath: session.path) { try FileManager.default.removeItem(at: session) }
      }
    } catch { throw error }
  }
  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
extension Commit {
  public var fullMessage: String { subject + (body.isEmpty ? "" : "\n\n" + body) }
}
