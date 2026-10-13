import Foundation

public struct Commit: Identifiable, Equatable {
  public var id: String { hash }
  public let hash: String
  public let parents: [String]
  public let author: String
  public let email: String
  public let date: Date
  public let subject: String
  public let body: String
  public let decorations: [String]
  public var shortHash: String { String(hash.prefix(8)) }
  public init(
    hash: String, parents: [String], author: String, email: String = "", date: Date = Date(),
    subject: String, body: String = "", decorations: [String] = []
  ) {
    self.hash = hash
    self.parents = parents
    self.author = author
    self.email = email
    self.date = date
    self.subject = subject
    self.body = body
    self.decorations = decorations
  }
}
public struct Branch: Equatable {
  public enum Kind: String { case local, remote, tag }
  public let name: String
  public let fullRef: String
  public let hash: String
  public let kind: Kind
  public let current: Bool
  public let upstream: String
  public let tracking: String
}
public struct FileChange: Equatable {
  public let path: String
  public let oldPath: String?
  public let index: Character
  public let worktree: Character
  public var isUntracked: Bool { index == "?" }
  public var isConflicted: Bool {
    index == "U" || worktree == "U" || (index == "A" && worktree == "A")
      || (index == "D" && worktree == "D")
  }
  public var isStaged: Bool { index != " " && index != "?" }
  public var status: String {
    isConflicted
      ? "Conflict"
      : isUntracked
        ? "Unversioned"
        : index == "R"
          ? "Renamed"
          : index == "A" || worktree == "A"
            ? "Added" : index == "D" || worktree == "D" ? "Deleted" : "Modified"
  }
  public init(
    path: String, oldPath: String? = nil, index: Character = " ", worktree: Character = " "
  ) {
    self.path = path
    self.oldPath = oldPath
    self.index = index
    self.worktree = worktree
  }
}
public struct LogFilter: Equatable {
  public var text = ""
  public var regex = false
  public var matchCase = false
  public var branch: String?
  public var author: String?
  public var since: String?
  public var until: String?
  public var path: String?
  public var firstParent = false
  public var limit = 2000
  public init() {}
}
// Graph ordering needs ancestry beyond the visible log limit, but not messages,
// authors or decorations for every historical commit.
public struct CommitAncestry: Equatable {
  public let hash: String
  public let parents: [String]
  public init(hash: String, parents: [String]) {
    self.hash = hash
    self.parents = parents
  }
}
public struct RepositorySnapshot: Equatable {
  public let branches: [Branch]
  public let commits: [Commit]
  public let history: [Commit]
  public let graphAncestry: [CommitAncestry]
  public let changes: [FileChange]
  public let currentBranch: String
  public let remotes: [String]
  public let stashes: [String]
  public let operation: String?
  public init(
    branches: [Branch], commits: [Commit], changes: [FileChange], currentBranch: String,
    remotes: [String], stashes: [String], operation: String?, history: [Commit]? = nil,
    graphAncestry: [CommitAncestry]? = nil
  ) {
    self.branches = branches
    self.commits = commits
    self.history = history ?? commits
    self.graphAncestry = graphAncestry ?? (history ?? commits).map {
      CommitAncestry(hash: $0.hash, parents: $0.parents)
    }
    self.changes = changes
    self.currentBranch = currentBranch
    self.remotes = remotes
    self.stashes = stashes
    self.operation = operation
  }
}
public struct GitFailure: LocalizedError {
  public let command: String
  public let message: String
  public var errorDescription: String? { message }
  public init(_ message: String, command: String = "") {
    self.command = command
    self.message = message
  }
}

// A lane is carried forward until its parent is encountered. Merge edges are
// independent from row selection, so filtered history still renders consistently.
public struct GraphEdge {
  public let from: Int
  public let to: Int
  public let color: Int
}
public struct GraphSegment {
  public let fromLane: Double
  public let fromY: Double
  public let toLane: Double
  public let toY: Double
  public let color: Int
}
public struct GraphRow {
  public let lane: Int
  public let color: Int
  public let edges: [GraphEdge]
  public let laneCount: Int
  public let isMerge: Bool
  public let incoming: Bool
  public let incomingEdges: [GraphEdge]
  // Coordinates are normalized to the row: bottom = 0, node = 0.5, top = 1.
  // Split center-to-center connections at the shared row boundary, so diagonal
  // edges join the node rather than turning half a row before reaching it.
  public var segments: [GraphSegment] {
    incomingEdges.map { edge in
      GraphSegment(fromLane: Double(edge.from + edge.to) / 2, fromY: 1,
        toLane: Double(edge.to), toY: 0.5, color: edge.color)
    } + edges.map { edge in
      GraphSegment(fromLane: Double(edge.from), fromY: 0.5,
        toLane: Double(edge.from + edge.to) / 2, toY: 0, color: edge.color)
    }
  }
}
public enum CommitGraph {
  public static func layout(_ commits: [Commit], ancestry: [Commit] = [], heads: [String] = []) -> [GraphRow] {
    layout(commits, topology: ancestry.map { CommitAncestry(hash: $0.hash, parents: $0.parents) }, heads: heads)
  }

  public static func layout(_ commits: [Commit], topology: [CommitAncestry], heads: [String] = []) -> [GraphRow] {
    guard !commits.isEmpty else { return [] }
    let visible = Set(commits.map(\.hash))
    // A detached revision or a newly loaded old branch can lie outside the
    // cached topology. Never leave visible commits without an ancestry rank.
    let known = Set(topology.map(\.hash))
    let source = topology + commits.filter { !known.contains($0.hash) }.map {
      CommitAncestry(hash: $0.hash, parents: $0.parents)
    }
    let parentsByHash = Dictionary(
      source.map { ($0.hash, $0.parents) },
      uniquingKeysWith: { a, _ in a })
    func projectedParents(_ commit: Commit) -> [String] {
      var result: [String] = []
      var visited = Set<String>()
      for parent in commit.parents {
        var stack = [parent]
        while let hash = stack.popLast() {
          guard visited.insert(hash).inserted else { continue }
          if visible.contains(hash) {
            result.append(hash)
          } else {
            stack.append(contentsOf: (parentsByHash[hash] ?? []).reversed())
          }
        }
      }
      return result
    }
    // Assign stable ancestry order from branch tips before packing visible rows.
    // A new head can then occupy the left lane instead of always being appended
    // to the right of every older branch passing through the row.
    let sourceIndices = Dictionary(source.enumerated().map { ($0.element.hash, $0.offset) }, uniquingKeysWith: { a, _ in a })
    let orderedParents = parentsByHash.mapValues { parents in
      parents.filter { sourceIndices[$0] != nil }
    }
    let ancestors = Set(source.flatMap(\.parents))
    var ranks: [String: Int] = [:]
    var nextRank = 0
    for head in heads + source.filter({ !ancestors.contains($0.hash) }).map(\.hash) + source.map(\.hash) {
      guard ranks[head] == nil, sourceIndices[head] != nil else { continue }
      var stack = [head]
      while let hash = stack.last {
        let firstVisit = ranks[hash] == nil
        if firstVisit { ranks[hash] = nextRank }
        if let parent = orderedParents[hash]?.first(where: { ranks[$0] == nil }) {
          stack.append(parent)
        } else {
          if firstVisit { nextRank += 1 }
          stack.removeLast()
        }
      }
    }
    struct Connection: Hashable { let from: Int; let to: Int }
    struct Element {
      let connection: Connection?
      let rank: Int
      let origin: Int
      let destination: Int
    }
    let indices = Dictionary(commits.enumerated().map { ($0.element.hash, $0.offset) }, uniquingKeysWith: { a, _ in a })
    let parents = commits.map { projectedParents($0).compactMap { indices[$0] } }
    var active: [Connection] = []
    var elements: [[Element]] = []
    var positions: [[Connection: Int]] = []
    var nodeLanes: [Int] = []
    for (index, commit) in commits.enumerated() {
      active.removeAll { $0.to <= index }
      var row = active.map { edge in
        Element(connection: edge,
          rank: max(ranks[commits[edge.from].hash] ?? 0, ranks[commits[edge.to].hash] ?? 0),
          origin: edge.from, destination: edge.to)
      }
      row.append(Element(connection: nil, rank: ranks[commit.hash] ?? 0, origin: index, destination: index))
      row.sort {
        if $0.rank != $1.rank { return $0.rank < $1.rank }
        if $0.origin != $1.origin { return $0.origin < $1.origin }
        return $0.destination < $1.destination
      }
      elements.append(row)
      positions.append(Dictionary(uniqueKeysWithValues: row.enumerated().compactMap { offset, element in
        element.connection.map { ($0, offset) }
      }))
      nodeLanes.append(row.firstIndex { $0.connection == nil }!)
      active += parents[index].filter { $0 > index }.map { Connection(from: index, to: $0) }
    }
    var previousEdges: [GraphEdge] = []
    return commits.indices.map { index in
      var edges: [GraphEdge] = []
      if index + 1 < commits.count {
        for (position, element) in elements[index].enumerated() {
          let connections = element.connection.map { [$0] } ?? parents[index].filter { $0 > index }.map { Connection(from: index, to: $0) }
          for edge in connections {
            let destination = edge.to == index + 1 ? nodeLanes[index + 1] : positions[index + 1][edge]
            if let destination {
              // A branch keeps its color all the way to the common ancestor.
              // First-parent connections belong to the child; a merge's other
              // connections belong to the branches being merged into it.
              let owner = parents[edge.from].first == edge.to ? edge.from : edge.to
              edges.append(GraphEdge(from: position, to: destination, color: ranks[commits[owner].hash] ?? 0))
            }
          }
        }
      }
      let row = GraphRow(lane: nodeLanes[index], color: ranks[commits[index].hash] ?? 0,
        edges: edges, laneCount: max(elements[index].count, index + 1 < commits.count ? elements[index + 1].count : 0),
        isMerge: commits[index].parents.count > 1,
        incoming: previousEdges.contains { $0.to == nodeLanes[index] }, incomingEdges: previousEdges)
      previousEdges = edges
      return row
    }
  }

  public static func recommendedLaneCount(_ rows: [GraphRow]) -> Int {
    guard !rows.isEmpty else { return 2 }
    var weight = 0.0, total = 0.0, squares = 0.0
    for (index, row) in rows.prefix(20_000).enumerated() {
      let w = 1 - 0.9 * Double(index) / Double(max(1, min(rows.count, 20_000) - 1))
      let lanes = Double(row.laneCount)
      weight += w; total += lanes * w; squares += lanes * lanes * w
    }
    let average = total / weight
    return max(2, Int((average + sqrt(max(0, squares / weight - average * average))).rounded()))
  }
}
