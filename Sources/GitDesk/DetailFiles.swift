import Foundation
import GitDeskCore

final class FileNode: NSObject {
  let id: String
  let title: String
  let count: Int
  let kind: WorkingRow.Kind
  var file: FileChange?
  var children: [FileNode] = []
  init(_ row: WorkingRow) {
    id = row.id
    title = row.title
    count = row.count
    kind = row.kind
    file = row.file
  }
  var files: [FileChange] { file.map { [$0] } ?? children.flatMap(\.files) }
}

enum DetailFiles {
  static func tree(_ files: [FileChange], modules: [CommitModule], directories: Bool,
    byModule: Bool) -> [FileNode] {
    // Historical changes share the same grouping and compact directory rules.
    let rows = CommitChanges.rows(changes: files, ignored: [], modules: modules,
      directories: directories, byModule: byModule, collapsed: []).filter { $0.kind != .section }
    var roots: [FileNode] = []
    var ancestors: [FileNode] = []
    for row in rows {
      let node = FileNode(row)
      let depth = row.depth - 1
      while ancestors.count > depth { ancestors.removeLast() }
      if let parent = ancestors.last { parent.children.append(node) }
      else { roots.append(node) }
      if row.isGroup { ancestors.append(node) }
    }
    return roots
  }
}
