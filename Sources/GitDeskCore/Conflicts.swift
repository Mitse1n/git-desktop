import Foundation

public enum ConflictSide: Int { case ours = 2, theirs = 3 }

extension GitRepository {
  private func conflictObjects(_ file: FileChange) throws -> [Int: String] {
    let records = try runData(["ls-files", "--unmerged", "-z", "--", file.path]).split(separator: 0)
    var objects: [Int: String] = [:]
    for record in records {
      guard let tab = record.firstIndex(of: 9) else { continue }
      let fields = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
      if fields.count == 3, let stage = Int(fields[2]) { objects[stage] = String(fields[1]) }
    }
    guard !objects.isEmpty else {
      throw GitFailure("This file is no longer conflicted. Refresh before resolving it.")
    }
    return objects
  }
  // nil means this side deleted the file; empty Data means a real empty file.
  public func conflictContents(_ file: FileChange, side: ConflictSide) throws -> Data? {
    guard let object = try conflictObjects(file)[side.rawValue] else { return nil }
    let size = try run(["cat-file", "-s", object]).trimmingCharacters(in: .newlines)
    guard let bytes = Int(size), bytes <= 2_000_000 else {
      throw GitFailure("File exceeds the 2 MB preview limit.")
    }
    return try runData(["cat-file", "blob", object])
  }
  public func acceptConflicts(_ files: [FileChange], side: ConflictSide) throws {
    guard !files.isEmpty else { return }
    var present: [FileChange] = [], deleted: [FileChange] = []
    for file in files {
      if try conflictObjects(file)[side.rawValue] == nil { deleted.append(file) }
      else { present.append(file) }
    }
    if !present.isEmpty {
      try run(["checkout", side == .ours ? "--ours" : "--theirs", "--"] + present.map(\.path))
      try stage(present)
    }
    if !deleted.isEmpty {
      try run(["rm", "-f", "--"] + deleted.map(\.path))
    }
  }
  public func saveConflict(_ file: FileChange, contents: Data) throws {
    _ = try conflictObjects(file)
    try contents.write(to: workingDirectory.appendingPathComponent(file.path), options: .atomic)
    try stage([file])
  }
}
