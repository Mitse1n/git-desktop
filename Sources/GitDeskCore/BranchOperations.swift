import Foundation

extension GitRepository {
  /// IDEA fast-forwards non-current branches with remote:local refspecs;
  /// the current branch uses the merge update method.
  public func updateBranches(_ selected: [Branch]) throws {
    let refs = Set(selected.map(\.fullRef))
    let branches = try self.branches().filter { refs.contains($0.fullRef) }
    guard !branches.isEmpty, branches.count == refs.count,
      branches.allSatisfy({ $0.kind == .local && !$0.upstream.isEmpty }) else {
      throw GitFailure("Every selected local branch must have an upstream configured.")
    }
    let current = try run(["symbolic-ref", "--quiet", "HEAD"], allowFailure: true)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let worktrees = try run(["worktree", "list", "--porcelain"])
    for branch in branches where branch.fullRef != current {
      guard !worktrees.components(separatedBy: "\n").contains("branch " + branch.fullRef) else {
        throw GitFailure("\(branch.name) is checked out in another worktree. Update it there.")
      }
    }
    var fetches: [String: [String]] = [:]
    for branch in branches {
      let remote = try run(["config", "--get", "branch.\(branch.name).remote"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let source = try run(["config", "--get", "branch.\(branch.name).merge"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !source.isEmpty else { throw GitFailure("Missing upstream for \(branch.name).") }
      fetches[remote, default: []].append(branch.fullRef == current ? source : source + ":" + branch.fullRef)
    }
    // Without '+' Git refuses divergent histories and branches checked out in
    // another worktree. Git publishes the refs with its own locking checks.
    for remote in fetches.keys.sorted() {
      try run(["fetch", "--", remote] + fetches[remote]!)
    }
    if let branch = branches.first(where: { $0.fullRef == current }) {
      let upstream = try resolve(branch.name + "@{upstream}")
      try run(["merge", "--no-edit", upstream])
    }
  }

  public func deleteBranches(_ selected: [Branch]) throws {
    let refs = Set(selected.map(\.fullRef))
    let branches = try self.branches().filter { refs.contains($0.fullRef) }
    guard !branches.isEmpty, branches.count == refs.count,
      !branches.contains(where: \.current) else {
      throw GitFailure("The current branch cannot be deleted.")
    }
    // Git refuses unmerged local branches and branches used by other worktrees.
    for kind in [Branch.Kind.local, .remote, .tag] {
      let names = branches.filter { $0.kind == kind }.map(\.name)
      guard !names.isEmpty else { continue }
      switch kind {
      case .local: try run(["branch", "-d", "--"] + names)
      case .remote: try run(["branch", "-rd", "--"] + names)
      case .tag: try run(["tag", "-d", "--"] + names)
      }
    }
  }
}
