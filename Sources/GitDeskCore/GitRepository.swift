import Foundation

public final class GitRepository {
  public let root: URL
  public var onCommand: ((String, String, Int32) -> Void)?
  public init(url: URL) throws {
    root = url.standardizedFileURL
    let actual = try run(["rev-parse", "--show-toplevel"]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard !actual.isEmpty else { throw GitFailure("Select a working-tree Git repository.") }
    rootURL = URL(fileURLWithPath: actual)
  }
  public init(directory: URL) { root = directory.standardizedFileURL }
  private var rootURL: URL?
  public var workingDirectory: URL { rootURL ?? root }
  @discardableResult public func run(
    _ args: [String], allowFailure: Bool = false, environment: [String: String] = [:]
  ) throws -> String {
    String(
      decoding: try runData(args, allowFailure: allowFailure, environment: environment),
      as: UTF8.self)
  }
  public func runData(
    _ args: [String], allowFailure: Bool = false, environment: [String: String] = [:]
  ) throws -> Data {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    let pathCommands = ["add", "reset", "restore", "rm", "diff", "diff-tree", "log", "checkout", "ls-files"]
    let literal = pathCommands.contains(args.first ?? "") && args.contains("--")
    task.arguments =
      (literal ? ["--literal-pathspecs"] : []) + [
        "-c", "color.ui=false", "-c", "core.quotepath=false",
      ] + args
    task.currentDirectoryURL = workingDirectory
    var env = ProcessInfo.processInfo.environment
    env["LC_ALL"] = "en_US.UTF-8"
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_PAGER"] = "cat"
    env.removeValue(forKey: "GIT_LITERAL_PATHSPECS")
    env.merge(environment) { _, new in new }
    task.environment = env
    task.standardInput = FileHandle.nullDevice
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
      "gitdesk-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temp) }
    let outURL = temp.appendingPathComponent("out")
    let errURL = temp.appendingPathComponent("err")
    FileManager.default.createFile(
      atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    FileManager.default.createFile(
      atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let out = try FileHandle(forWritingTo: outURL)
    let err = try FileHandle(forWritingTo: errURL)
    defer {
      try? out.close()
      try? err.close()
    }
    task.standardOutput = out
    task.standardError = err
    let finished = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in finished.signal() }
    try task.run()
    if finished.wait(timeout: .now() + 120) == .timedOut {
      task.terminate()
      if finished.wait(timeout: .now() + 0.2) == .timedOut {
        kill(task.processIdentifier, SIGKILL)
        finished.wait()
      }
      throw GitFailure(
        "Git operation timed out after 120 seconds.", command: args.joined(separator: " "))
    }
    let output = try Data(contentsOf: outURL)
    let errors = try Data(contentsOf: errURL)
    let command = "git " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    onCommand?(command, String(decoding: output + errors, as: UTF8.self), task.terminationStatus)
    if task.terminationStatus != 0 && !allowFailure {
      throw GitFailure(
        String(decoding: errors.isEmpty ? output : errors, as: UTF8.self).trimmingCharacters(
          in: .whitespacesAndNewlines), command: command)
    }
    return output
  }
  public var hasHead: Bool {
    ((try? run(["rev-parse", "--verify", "HEAD"], allowFailure: true)) ?? "").count > 10
  }
  public func resolve(_ ref: String) throws -> String {
    try run(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"]).trimmingCharacters(
      in: .whitespacesAndNewlines)
  }
  public func branches() throws -> [Branch] {
    let output = try run([
      "for-each-ref",
      "--format=%(refname)%00%(objectname)%00%(HEAD)%00%(upstream:short)%00%(upstream:track)",
      "refs/heads", "refs/remotes", "refs/tags",
    ])
    return output.split(separator: "\n").compactMap { line in
      let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
      guard f.count == 5 else { return nil }
      let kind: Branch.Kind =
        f[0].hasPrefix("refs/heads/") ? .local : f[0].hasPrefix("refs/remotes/") ? .remote : .tag
      let prefix = kind == .local ? "refs/heads/" : kind == .remote ? "refs/remotes/" : "refs/tags/"
      if kind == .remote && f[0].hasSuffix("/HEAD") { return nil }
      return Branch(
        name: String(f[0].dropFirst(prefix.count)), fullRef: f[0], hash: f[1], kind: kind,
        current: f[2] == "*", upstream: f[3], tracking: f[4])
    }
  }
  public static func parseStatus(_ data: Data) -> [FileChange] {
    let parts = data.split(separator: 0, omittingEmptySubsequences: true).map {
      String(decoding: $0, as: UTF8.self)
    }
    var result: [FileChange] = []
    var i = 0
    while i < parts.count {
      let chars = Array(parts[i])
      i += 1
      guard chars.count >= 4 else { continue }
      let path = String(chars.dropFirst(3))
      var old: String?
      if chars[0] == "R" || chars[0] == "C" || chars[1] == "R" || chars[1] == "C" {
        if i < parts.count {
          old = parts[i]
          i += 1
        }
      }
      result.append(FileChange(path: path, oldPath: old, index: chars[0], worktree: chars[1]))
    }
    return result
  }
  public func status() throws -> [FileChange] {
    Self.parseStatus(try runData(["status", "--porcelain=v1", "-z", "--untracked-files=all"]))
  }
  public func ignoredPaths() throws -> [String] {
    // Keep ignored directories collapsed instead of walking build artifacts file by file.
    try runData(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"])
      .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
  }
  public func log(_ filter: LogFilter = LogFilter()) throws -> [Commit] {
    guard hasHead else { return [] }
    var args = [
      "log", "--topo-order", "--date-order", "-n", String(filter.limit),
      "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%b%x00%D%x00",
    ]
    if let ref = filter.branch { args.append(try resolve(ref)) } else { args += ["--all", "HEAD"] }
    if let author = filter.author, !author.isEmpty {
      args += ["--author=" + author, "--fixed-strings"]
    }
    if let since = filter.since { args += ["--since=" + since] }
    if let until = filter.until { args += ["--until=" + until] }
    if filter.firstParent { args.append("--first-parent") }
    if let path = filter.path, !path.isEmpty { args += ["--", path] }
    let fields = try run(args).components(separatedBy: "\0")
    var commits: [Commit] = []
    var i = 0
    while i + 7 < fields.count {
      let hash = fields[i].trimmingCharacters(in: .whitespacesAndNewlines)
      if !hash.isEmpty {
        commits.append(
          Commit(
            hash: hash, parents: fields[i + 1].split(separator: " ").map(String.init),
            author: fields[i + 2], email: fields[i + 3],
            date: Date(timeIntervalSince1970: Double(fields[i + 4]) ?? 0), subject: fields[i + 5],
            body: fields[i + 6].trimmingCharacters(in: .newlines),
            decorations: fields[i + 7].components(separatedBy: ", ").filter { !$0.isEmpty }))
      }
      i += 8
    }
    guard !filter.text.isEmpty else { return commits }
    if filter.regex {
      let pattern = try NSRegularExpression(
        pattern: filter.text, options: filter.matchCase ? [] : .caseInsensitive)
      return commits.filter { c in
        let text = c.hash + " " + c.subject + "\n" + c.body
        return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
      }
    }
    return commits.filter {
      let value = $0.hash + " " + $0.subject + "\n" + $0.body
      return value.range(of: filter.text, options: filter.matchCase ? [] : .caseInsensitive) != nil
    }
  }
  private func graphAncestry() throws -> [CommitAncestry] {
    guard hasHead else { return [] }
    return try run(["rev-list", "--topo-order", "--date-order", "--parents", "--all", "HEAD"])
      .split(separator: "\n").compactMap { line in
        let hashes = line.split(separator: " ")
        guard let hash = hashes.first else { return nil }
        return CommitAncestry(hash: String(hash), parents: hashes.dropFirst().map(String.init))
      }
  }
  public func snapshot(filter: LogFilter = LogFilter()) throws -> RepositorySnapshot {
    var refs = try branches()
    let branch = try run(["symbolic-ref", "--quiet", "--short", "HEAD"], allowFailure: true)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if refs.isEmpty && !branch.isEmpty {
      refs = [
        Branch(
          name: branch, fullRef: "refs/heads/" + branch, hash: "", kind: .local, current: true,
          upstream: "", tracking: "")
      ]
    }
    let gitDir = try run(["rev-parse", "--absolute-git-dir"]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let operations = [
      ("rebase-merge", "rebase"), ("rebase-apply", "rebase"), ("MERGE_HEAD", "merge"),
      ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert"),
    ]
    let operation = operations.first {
      FileManager.default.fileExists(atPath: gitDir + "/" + $0.0)
    }?.1
    var historyFilter = LogFilter()
    historyFilter.limit = filter.limit
    let history = try log(historyFilter)
    return RepositorySnapshot(
      branches: refs, commits: filter == historyFilter ? history : try log(filter),
      changes: try status(), currentBranch: branch.isEmpty ? "Detached HEAD" : branch,
      remotes: try run(["remote"]).split(separator: "\n").map(String.init),
      stashes: try run(["stash", "list", "--format=%gd: %s"]).split(separator: "\n").map(
        String.init), operation: operation, history: history, graphAncestry: try graphAncestry())
  }
  // Changing a history filter does not change refs, the worktree, or stashes.
  // Keep their last snapshot until an explicit/background repository refresh.
  public func filteredSnapshot(from snapshot: RepositorySnapshot, filter: LogFilter) throws
    -> RepositorySnapshot
  {
    RepositorySnapshot(
      branches: snapshot.branches, commits: try log(filter), changes: snapshot.changes,
      currentBranch: snapshot.currentBranch, remotes: snapshot.remotes, stashes: snapshot.stashes,
      operation: snapshot.operation, history: snapshot.history, graphAncestry: snapshot.graphAncestry)
  }
  public static func parseNameStatus(_ data: Data) -> [FileChange] {
    let fields = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    var result: [FileChange] = []
    var i = 0
    while i + 1 < fields.count {
      let status = fields[i].first ?? "M"
      i += 1
      if status == "R" || status == "C", i + 1 < fields.count {
        result.append(FileChange(path: fields[i + 1], oldPath: fields[i], index: status))
        i += 2
      } else {
        result.append(FileChange(path: fields[i], index: status))
        i += 1
      }
    }
    return result
  }
  public func changes(in commit: Commit) throws -> [FileChange] {
    // IDEA displays a merge against its first parent.
    if let parent = commit.parents.first { return try compare(from: parent, to: commit.hash) }
    return Self.parseNameStatus(
      try runData([
        "diff-tree", "--root", "--no-commit-id", "-r", "--name-status", "-z", "-M", commit.hash,
      ]))
  }
  public func compare(from: String, to: String) throws -> [FileChange] {
    Self.parseNameStatus(
      try runData(["diff", "--name-status", "-z", "-M", try resolve(from), try resolve(to)]))
  }
  public func blob(ref: String, path: String, limit: Int? = nil) throws -> Data {
    let object = (ref == ":" ? ":" : ref + ":") + path
    if let limit {
      let size = try run(["cat-file", "-s", object], allowFailure: true).trimmingCharacters(
        in: .whitespacesAndNewlines)
      if let bytes = Int(size), bytes > limit {
        throw GitFailure("File exceeds the 2 MB diff preview limit.")
      }
    }
    return try runData(["show", object], allowFailure: true)
  }
  public func readWorkingFile(_ path: String, limit: Int = 2_000_000) throws -> Data {
    let url = workingDirectory.appendingPathComponent(path)
    let attributes: [FileAttributeKey: Any]
    do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) } catch {
      let code = (error as NSError).code
      if code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError { return Data() }
      throw error
    }
    if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
      return Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
    }
    if attributes[.type] as? FileAttributeType == .typeDirectory {
      throw GitFailure("Directory or submodule changes cannot be shown as a text diff.")
    }
    if ((attributes[.size] as? NSNumber)?.intValue ?? 0) > limit {
      throw GitFailure("File exceeds the 2 MB diff preview limit.")
    }
    return try Data(contentsOf: url)
  }
  public func contents(
    change: FileChange, commit: Commit? = nil, staged: Bool = false,
    comparison: (String, String)? = nil
  ) throws -> (Data, Data) {
    if let comparison {
      return (
        try blob(ref: comparison.0, path: change.oldPath ?? change.path, limit: 2_000_000),
        comparison.1 == "WORKTREE"
          ? try readWorkingFile(change.path)
          : try blob(ref: comparison.1, path: change.path, limit: 2_000_000)
      )
    }
    if let commit {
      return (
        try commit.parents.first.map {
          try blob(ref: $0, path: change.oldPath ?? change.path, limit: 2_000_000)
        } ?? Data(), try blob(ref: commit.hash, path: change.path, limit: 2_000_000)
      )
    }
    let before =
      staged
      ? (hasHead
        ? try blob(ref: "HEAD", path: change.oldPath ?? change.path, limit: 2_000_000) : Data())
      : try blob(ref: ":", path: change.path, limit: 2_000_000)
    let after =
      staged
      ? try blob(ref: ":", path: change.path, limit: 2_000_000) : try readWorkingFile(change.path)
    return (before, after)
  }
  public func workingDiff(change: FileChange) throws -> (Data, Data) {
    let old =
      hasHead
      ? try blob(ref: "HEAD", path: change.oldPath ?? change.path, limit: 2_000_000) : Data()
    return (old, try readWorkingFile(change.path))
  }
  public func stage(_ changes: [FileChange]) throws { try run(["add", "--"] + paths(changes)) }
  public func unstage(_ changes: [FileChange]) throws {
    if hasHead {
      try run(["reset", "HEAD", "--"] + paths(changes))
    } else {
      try run(["rm", "--cached", "-f", "--"] + paths(changes))
    }
  }
  private func paths(_ changes: [FileChange]) -> [String] {
    Array(Set(changes.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) })).sorted()
  }
  public func commit(message: String, changes: [FileChange], amend: Bool = false,
    author: String? = nil, signOff: Bool = false) throws {
    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GitFailure("Enter a commit message.")
    }
    let currentChanges = try status()
    var args = ["commit", "-m", message]
    if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      args += ["--author", author]
    }
    if signOff { args.append("--signoff") }
    guard !currentChanges.contains(where: \.isConflicted) else {
      throw GitFailure("Resolve all conflicts before committing.")
    }
    let mergeFile = try run(["rev-parse", "--git-path", "MERGE_HEAD"]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let mergeURL =
      mergeFile.hasPrefix("/")
      ? URL(fileURLWithPath: mergeFile) : workingDirectory.appendingPathComponent(mergeFile)
    if FileManager.default.fileExists(atPath: mergeURL.path) {
      guard !amend,
        Set(changes.map(\.path)).isSuperset(
          of: Set(currentChanges.filter { !$0.isUntracked }.map(\.path)))
      else { throw GitFailure("Select all merge changes to complete the merge commit.") }
      if !changes.isEmpty { try stage(changes) }
      try run(args)
      return
    }
    guard !changes.isEmpty || amend else { throw GitFailure("Select files to commit.") }
    let indexURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "gitdesk-index-" + UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: indexURL)
      try? FileManager.default.removeItem(atPath: indexURL.path + ".lock")
    }
    let env = ["GIT_INDEX_FILE": indexURL.path]
    try run(hasHead ? ["read-tree", "HEAD"] : ["read-tree", "--empty"], environment: env)
    let selectedPaths = paths(changes)
    if !selectedPaths.isEmpty { try run(["add", "--"] + selectedPaths, environment: env) }
    if amend { args.append("--amend") }
    try run(args, environment: env)
    // Synchronize only the committed paths. Unrelated staged files remain staged.
    if !selectedPaths.isEmpty {
      do { try run(["reset", "HEAD", "--"] + selectedPaths) } catch {
        throw GitFailure(
          "Commit was created, but updating the index failed. Refresh before retrying.\n"
            + error.localizedDescription)
      }
    }
  }
  public func checkout(_ branch: Branch) throws {
    switch branch.kind {
    case .local: try run(["switch", "--", branch.name])
    case .remote: try run(["switch", "--track", branch.name])
    case .tag: try run(["switch", "--detach", try resolve(branch.fullRef)])
    }
  }
  public func createBranch(_ name: String, start: String = "HEAD", checkout: Bool = true) throws {
    try run(["check-ref-format", "--branch", name])
    if !hasHead && start == "HEAD" {
      try run(["symbolic-ref", "HEAD", "refs/heads/" + name])
      return
    }
    if checkout {
      try run(["switch", "-c", name, try resolve(start)])
    } else {
      try run(["branch", name, try resolve(start)])
    }
  }
  public func discard(_ changes: [FileChange]) throws {
    guard !changes.contains(where: \.isUntracked) else {
      throw GitFailure("Unversioned files cannot be rolled back. Use Move to Trash instead.")
    }
    // IDEA rolls newly added files back to unversioned files, retaining their contents.
    let added = changes.filter { $0.index == "A" || $0.index == "C" }
    let existing = changes.filter { $0.index != "A" && $0.index != "C" }
    if !existing.isEmpty {
      try run(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + paths(existing))
    }
    if !added.isEmpty { try run(["rm", "--cached", "-f", "--"] + added.map(\.path)) }
  }
}
