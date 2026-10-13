import GitDeskCore

// Value-only preparation: safe to build on the repository queue. Keep only the
// current presentation; arrays and sets share storage with the displayed state.
struct RepositoryHistoryPresentation {
  private let commits: [Commit]
  private let history: [Commit]
  private let topology: [CommitAncestry]
  private let branches: [Branch]
  private let currentBranch: String
  let showLongEdges: Bool
  let graphs: [GraphRow]
  let currentBranchHistory: Set<String>

  func matches(_ snapshot: RepositorySnapshot) -> Bool {
    commits == snapshot.commits && history == snapshot.history
      && topology == snapshot.graphAncestry && branches == snapshot.branches
      && currentBranch == snapshot.currentBranch
  }
  static func prepare(_ snapshot: RepositorySnapshot, reusing previous: Self? = nil, showLongEdges: Bool = false) -> Self {
    if let previous, previous.matches(snapshot), previous.showLongEdges == showLongEdges { return previous }
    return Self(snapshot, reusing: previous, showLongEdges: showLongEdges)
  }
  init(_ data: RepositorySnapshot, reusing previous: Self? = nil, showLongEdges: Bool = false) {
    self.showLongEdges = showLongEdges
    commits = data.commits
    history = data.history
    topology = data.graphAncestry
    branches = data.branches
    currentBranch = data.currentBranch
    // Preserve the exact head order, lane/color algorithm and detached-HEAD
    // fallback used by the original main-thread implementation.
    let graphHeads = data.branches.sorted {
      func priority(_ branch: Branch) -> Int {
        if branch.kind == .local && ["main", "master"].contains(branch.name) { return 0 }
        if branch.kind == .remote && ["main", "master"].contains(String(branch.name.split(separator: "/").last ?? "")) { return 1 }
        if branch.kind == .local { return 2 }
        return branch.kind == .remote ? 3 : 4
      }
      return priority($0) == priority($1) ? $0.name < $1.name : priority($0) < priority($1)
    }.map(\.hash)
    graphs = CommitGraph.layout(data.commits, topology: data.graphAncestry, heads: graphHeads, showLongEdges: showLongEdges)
    // Log filters change visible graph rows, not HEAD reachability. Reuse this
    // set instead of temporarily holding two full ancestor indexes/sets.
    if let previous, previous.topology == data.graphAncestry,
      previous.branches == data.branches, previous.history == data.history,
      previous.currentBranch == data.currentBranch {
      currentBranchHistory = previous.currentBranchHistory
      return
    }
    let ancestry = Dictionary(data.graphAncestry.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
    let head = data.branches.first(where: \.current)?.hash ?? data.history.first {
      $0.decorations.contains { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") }
    }?.hash
    var pending = head.map { [$0] } ?? []
    var reachable = Set<String>()
    while let hash = pending.popLast() {
      if reachable.insert(hash).inserted { pending.append(contentsOf: ancestry[hash]?.parents ?? []) }
    }
    currentBranchHistory = reachable
  }
}
