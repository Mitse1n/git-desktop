import Foundation

public struct DiffLine: Equatable {
  public enum Kind { case unchanged, added, removed, modified }
  public let left: String?
  public let right: String?
  public let leftNumber: Int?
  public let rightNumber: Int?
  public let kind: Kind
}
public struct TextDiff {
  public let rows: [DiffLine]
  public let binary: Bool
  public let tooLarge: Bool
  public let identical: Bool
  public var changes: [Int] {
    rows.indices.filter {
      rows[$0].kind != .unchanged && ($0 == 0 || rows[$0 - 1].kind == .unchanged)
    }
  }
  public init(before: Data, after: Data, ignoreWhitespace: Bool = false) {
    binary =
      before.contains(0) || after.contains(0) || String(data: before, encoding: .utf8) == nil
      || String(data: after, encoding: .utf8) == nil
    tooLarge = before.count + after.count > 2_000_000
    identical = before == after
    guard !binary, !tooLarge else {
      rows = []
      return
    }
    func lines(_ data: Data) -> [String] {
      guard !data.isEmpty else { return [] }
      var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
      if lines.last == "" { lines.removeLast() }
      return lines
    }
    let a = lines(before)
    let b = lines(after)
    guard a.count + b.count <= 20000 else {
      rows = []
      return
    }
    let normal: (String) -> String = {
      ignoreWhitespace
        ? $0.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined() : $0
    }
    let delta = b.map(normal).difference(from: a.map(normal))
    var removed = Set<Int>()
    var inserted = Set<Int>()
    for change in delta {
      switch change {
      case .remove(let i, _, _): removed.insert(i)
      case .insert(let i, _, _): inserted.insert(i)
      }
    }
    var result: [DiffLine] = []
    var i = 0
    var j = 0
    while i < a.count || j < b.count {
      var old: [(Int, String)] = []
      var new: [(Int, String)] = []
      while i < a.count && removed.contains(i) {
        old.append((i + 1, a[i]))
        i += 1
      }
      while j < b.count && inserted.contains(j) {
        new.append((j + 1, b[j]))
        j += 1
      }
      for k in 0..<max(old.count, new.count) {
        let l = k < old.count ? old[k] : nil
        let r = k < new.count ? new[k] : nil
        result.append(
          DiffLine(
            left: l?.1, right: r?.1, leftNumber: l?.0, rightNumber: r?.0,
            kind: l == nil ? .added : r == nil ? .removed : .modified))
      }
      if i < a.count && j < b.count {
        result.append(
          DiffLine(left: a[i], right: b[j], leftNumber: i + 1, rightNumber: j + 1, kind: .unchanged)
        )
        i += 1
        j += 1
      } else if old.isEmpty && new.isEmpty {
        break
      }
    }
    // Preserve a visible indication when only the final newline changed.
    if result.allSatisfy({ $0.kind == .unchanged }) && before != after && !ignoreWhitespace {
      result.append(
        DiffLine(
          left: before.last == 10 ? "" : "No newline at end of file",
          right: after.last == 10 ? "" : "No newline at end of file", leftNumber: nil,
          rightNumber: nil, kind: .modified))
    }
    rows = result
  }
}
