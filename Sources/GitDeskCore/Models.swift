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
public struct RepositorySnapshot: Equatable {
  public let branches: [Branch]
  public let commits: [Commit]
  public let history: [Commit]
  public let changes: [FileChange]
  public let currentBranch: String
  public let remotes: [String]
  public let stashes: [String]
  public let operation: String?
  public init(
    branches: [Branch], commits: [Commit], changes: [FileChange], currentBranch: String,
    remotes: [String], stashes: [String], operation: String?, history: [Commit]? = nil
  ) {
    self.branches = branches
    self.commits = commits
    self.history = history ?? commits
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
public struct GraphRow {
  public let lane: Int
  public let color: Int
  public let edges: [GraphEdge]
  public let laneCount: Int
  public let isMerge: Bool
  public let incoming: Bool
}
public enum CommitGraph {
  public static func layout(_ commits: [Commit], ancestry: [Commit] = []) -> [GraphRow] {
    let visible = Set(commits.map(\.hash))
    let parentsByHash = Dictionary(
      (ancestry.isEmpty ? commits : ancestry).map { ($0.hash, $0.parents) },
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
    var lanes: [(hash: String, color: Int)] = []
    var nextColor = 0
    return commits.map { commit in
      let parents = projectedParents(commit)
      let incoming = lanes.contains { $0.hash == commit.hash }
      let lane: Int
      if let existing = lanes.firstIndex(where: { $0.hash == commit.hash }) {
        lane = existing
      } else {
        lane = lanes.count
        lanes.append((commit.hash, nextColor))
        nextColor += 1
      }
      let before = lanes
      let color = lanes[lane].color
      lanes.remove(at: lane)
      for (i, parent) in parents.enumerated() where !lanes.contains(where: { $0.hash == parent }) {
        let c = i == 0 ? color : nextColor
        if i > 0 { nextColor += 1 }
        lanes.insert((parent, c), at: min(lane + i, lanes.count))
      }
      var edges: [GraphEdge] = []
      for (i, item) in before.enumerated() where item.hash != commit.hash {
        if let to = lanes.firstIndex(where: { $0.hash == item.hash }) {
          edges.append(GraphEdge(from: i, to: to, color: item.color))
        }
      }
      for parent in parents {
        if let to = lanes.firstIndex(where: { $0.hash == parent }) {
          edges.append(GraphEdge(from: lane, to: to, color: lanes[to].color))
        }
      }
      return GraphRow(
        lane: lane, color: color, edges: edges, laneCount: max(before.count, lanes.count),
        isMerge: commit.parents.count > 1, incoming: incoming)
    }
  }
}
