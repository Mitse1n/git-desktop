import Foundation
import GitDeskCore

struct CommitModule: Equatable {
  let name: String
  let root: String

  static func discover(in repository: URL) -> [CommitModule] {
    let project = repository.standardizedFileURL
    let descriptors = ModuleXML.read(project.appendingPathComponent(".idea/modules.xml"))
    var modules: [CommitModule] = []
    for attributes in descriptors.elements where attributes.element == "module" {
      guard let path = attributes.values["filepath"] ?? attributes.values["fileurl"],
        let file = resolve(path, project: project, module: project),
        file.path.hasPrefix(project.path + "/") else { continue }
      for content in ModuleXML.read(file).elements where content.element == "content" {
        guard let url = content.values["url"],
          let root = resolve(url, project: project, module: file.deletingLastPathComponent()),
          root.path == project.path || root.path.hasPrefix(project.path + "/") else { continue }
        let relative = root.path == project.path ? "" : String(root.path.dropFirst(project.path.count + 1))
        modules.append(CommitModule(name: file.deletingPathExtension().lastPathComponent, root: relative))
      }
    }
    if modules.isEmpty { modules = [CommitModule(name: project.lastPathComponent, root: "")] }
    return modules.sorted { $0.root.count > $1.root.count }
  }
  private static func resolve(_ value: String, project: URL, module: URL) -> URL? {
    var path = value.replacingOccurrences(of: "$PROJECT_DIR$", with: project.path)
      .replacingOccurrences(of: "$MODULE_DIR$", with: module.path)
    if path.hasPrefix("file://") { path = String(path.dropFirst(7)) }
    guard path.hasPrefix("/"), !path.contains("$") else { return nil }
    return URL(fileURLWithPath: path.removingPercentEncoding ?? path).standardizedFileURL
  }
}

private final class ModuleXML: NSObject, XMLParserDelegate {
  var elements: [(element: String, values: [String: String])] = []
  static func read(_ url: URL) -> ModuleXML {
    let result = ModuleXML()
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= 1_048_576, let data = try? Data(contentsOf: url) else { return result }
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = result
    if !parser.parse() { result.elements = [] }
    return result
  }
  func parser(_ parser: XMLParser, didStartElement elementName: String,
    namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
    if elementName == "module" || elementName == "content" {
      elements.append((elementName, attributeDict))
    }
  }
}

struct WorkingRow {
  enum Kind { case section, module, directory, file, ignored }
  let id: String
  let title: String
  let kind: Kind
  let depth: Int
  let files: [FileChange]
  let count: Int
  let path: String?
  let paths: [String]
  var isGroup: Bool { kind == .section || kind == .module || kind == .directory }
  var file: FileChange? { kind == .file ? files.first : nil }
}

enum CommitChanges {
  private final class Node {
    var id: String
    var title: String
    let kind: WorkingRow.Kind
    var file: FileChange?
    var path: String?
    var children: [Node] = []
    init(_ id: String, _ title: String, _ kind: WorkingRow.Kind) {
      self.id = id; self.title = title; self.kind = kind
    }
    var files: [FileChange] { file.map { [$0] } ?? children.flatMap(\.files) }
    var count: Int { path != nil ? 1 : children.reduce(0) { $0 + $1.count } }
    var paths: [String] { path.map { [$0] } ?? children.flatMap(\.paths) }
  }
  static func rows(changes: [FileChange], ignored: [String], modules: [CommitModule],
    directories: Bool, byModule: Bool, collapsed: Set<String>) -> [WorkingRow] {
    var sections: [Node] = []
    for (title, files) in [("Conflicts", changes.filter(\.isConflicted)),
      ("Changes", changes.filter { !$0.isUntracked && !$0.isConflicted }),
      ("Unversioned Files", changes.filter(\.isUntracked))] where title == "Changes" || !files.isEmpty {
      let section = Node(title, title, .section)
      for file in files { insert(file.path, file: file, in: section, modules: modules,
        directories: directories, byModule: byModule) }
      sections.append(section)
    }
    if !ignored.isEmpty {
      let section = Node("Ignored Files", "Ignored Files", .section)
      for path in ignored { insert(path, file: nil, in: section, modules: modules,
        directories: directories, byModule: byModule) }
      sections.append(section)
    }
    var result: [WorkingRow] = []
    func flatten(_ node: Node, depth: Int) {
      // Compact chains such as Sources/GitDesk, as the IDE's changes tree does.
      while node.kind == .directory, node.children.count == 1,
        let child = node.children.first, child.kind == .directory {
        node.title += "/" + child.title
        node.id = child.id
        node.children = child.children
      }
      result.append(WorkingRow(id: node.id, title: node.title, kind: node.kind,
        depth: depth, files: node.files, count: node.count, path: node.path, paths: node.paths))
      guard !collapsed.contains(node.id) else { return }
      let children = node.children.sorted {
        let a = $0.kind == .module || $0.kind == .directory
        let b = $1.kind == .module || $1.kind == .directory
        return a != b ? a : $0.title.localizedStandardCompare($1.title) == .orderedAscending
      }
      for child in children { flatten(child, depth: depth + 1) }
    }
    for section in sections { flatten(section, depth: 0) }
    return result
  }
  private static func insert(_ path: String, file: FileChange?, in section: Node,
    modules: [CommitModule], directories: Bool, byModule: Bool) {
    var parent = section
    var relative = path
    if byModule, let module = modules.filter({
      $0.root.isEmpty || path.hasPrefix($0.root + "/")
    }).max(by: { $0.root.count < $1.root.count }) {
      let id = section.id + "\0module:" + module.name + ":" + module.root
      if let existing = parent.children.first(where: { $0.id == id }) { parent = existing }
      else {
        let node = Node(id, module.name, .module)
        parent.children.append(node); parent = node
      }
      if !module.root.isEmpty { relative = String(path.dropFirst(module.root.count + 1)) }
    }
    let parts = relative.split(separator: "/").map(String.init)
    if directories {
      var directoryID = parent.id
      for part in parts.dropLast() {
        directoryID += "/" + part
        if let existing = parent.children.first(where: { $0.id == directoryID }) { parent = existing }
        else {
          let node = Node(directoryID, part, .directory)
          parent.children.append(node); parent = node
        }
      }
    }
    let leaf = Node(section.id + "\0file:" + path,
      directories ? parts.last ?? path : relative, file == nil ? .ignored : .file)
    leaf.file = file; leaf.path = path
    parent.children.append(leaf)
  }
}
