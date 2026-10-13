import Foundation
import GitDeskCore

final class BranchNode: NSObject {
  var title: String
  var branch: Branch?
  var children: [BranchNode] = []
  init(_ title: String, branch: Branch? = nil) {
    self.title = title
    self.branch = branch
  }
}

enum BranchTree {
  enum Icon { case current, favorite, branch, tag }
  static let defaultFavoriteRefs: Set<String> = [
    "refs/heads/main", "refs/heads/master",
    "refs/remotes/origin/main", "refs/remotes/origin/master",
  ]
  static func favorites(in defaults: UserDefaults = .standard) -> Set<String> {
    guard let saved = defaults.stringArray(forKey: "favoriteRefs") else { return defaultFavoriteRefs }
    return Set(saved)
  }
  static func icon(for branch: Branch, favorites: Set<String>) -> Icon {
    if branch.current { return .current }
    if favorites.contains(branch.fullRef) { return .favorite }
    return branch.kind == .tag ? .tag : .branch
  }
  static func build(_ branches: [Branch], favorites: Set<String>, search: String = "",
    favoriteOnly: Bool = false, grouped: Bool = true, showTags: Bool = true) -> [BranchNode] {
    var nodes = [BranchNode("HEAD (Current Branch)")]
    for (kind, title) in [(Branch.Kind.local, "Local"), (.remote, "Remote"), (.tag, "Tags")] {
      if kind == .tag && !showTags { continue }
      let group = BranchNode(title)
      let refs = branches.filter {
        $0.kind == kind && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
          && (!favoriteOnly || $0.current || favorites.contains($0.fullRef))
      }.sorted { a, b in
        if a.current != b.current { return a.current }
        let aFavorite = favorites.contains(a.fullRef), bFavorite = favorites.contains(b.fullRef)
        return aFavorite != bFavorite ? aFavorite : a.name.localizedStandardCompare(b.name) == .orderedAscending
      }
      for branch in refs {
        var parent = group
        let parts = grouped ? branch.name.split(separator: "/").map(String.init) : [branch.name]
        for part in parts.dropLast() {
          if let existing = parent.children.first(where: { $0.title == part && $0.branch == nil }) {
            parent = existing
          } else {
            let folder = BranchNode(part)
            parent.children.append(folder)
            parent = folder
          }
        }
        parent.children.append(BranchNode(parts.last ?? branch.name, branch: branch))
      }
      if !group.children.isEmpty { nodes.append(group) }
    }
    return nodes
  }
}
