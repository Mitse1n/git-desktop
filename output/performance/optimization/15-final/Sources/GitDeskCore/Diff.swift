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
    self = TextDiff(before: before, after: after, ignoreWhitespace: ignoreWhitespace, shouldCancel: { false })!
  }
  // Cancellation never returns a partial comparison that could be displayed.
  // The original non-failable API retains its exact result and limit semantics.
  public init?(before: Data, after: Data, ignoreWhitespace: Bool = false, shouldCancel: () -> Bool) {
    guard !shouldCancel() else { return nil }
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
    guard !shouldCancel() else { return nil }
    guard a.count + b.count <= 20000 else {
      rows = []
      return
    }
    let normal: (String) -> String = {
      ignoreWhitespace
        ? $0.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined() : $0
    }
    let normalizedA = ignoreWhitespace ? a.map(normal) : a
    let normalizedB = ignoreWhitespace ? b.map(normal) : b
    var removed = Set<Int>()
    var inserted = Set<Int>()
    if normalizedA == normalizedB {
      // Empty edit script, including ignored whitespace, is unambiguous.
    } else if !Self.prefersStandardDiff(normalizedA, normalizedB),
      let edits = Self.orderedUniqueEdits(normalizedA, normalizedB, shouldCancel: shouldCancel) {
      removed = edits.removed
      inserted = edits.inserted
    } else {
      guard !shouldCancel() else { return nil }
      // Repeated shared lines and reordering can have ambiguous alignments.
      // Preserve the original standard-library algorithm and its tie breaking.
      let delta = normalizedB.difference(from: normalizedA)
      for change in delta {
        switch change {
        case .remove(let i, _, _): removed.insert(i)
        case .insert(let i, _, _): inserted.insert(i)
        }
      }
    }
    guard !shouldCancel() else { return nil }
    var result: [DiffLine] = []
    var i = 0
    var j = 0
    while i < a.count || j < b.count {
      if (i + j) % 256 == 0 && shouldCancel() { return nil }
      var old: [(Int, String)] = []
      var new: [(Int, String)] = []
      while i < a.count && removed.contains(i) {
        if i % 256 == 0 && shouldCancel() { return nil }
        old.append((i + 1, a[i]))
        i += 1
      }
      while j < b.count && inserted.contains(j) {
        if j % 256 == 0 && shouldCancel() { return nil }
        new.append((j + 1, b[j]))
        j += 1
      }
      for k in 0..<max(old.count, new.count) {
        if k % 256 == 0 && shouldCancel() { return nil }
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

  private static func prefersStandardDiff(_ a: [String], _ b: [String]) -> Bool {
    // The standard algorithm is already efficient for sparse edits. A tiny
    // sample avoids building a hash index in that common case. This selects
    // between exact algorithms only; it never selects or approximates matches.
    guard a.count == b.count, a.count >= 64 else { return false }
    var matching = 0
    for sample in 0..<8 {
      let index = sample * (a.count - 1) / 7
      if a[index] == b[index] { matching += 1 }
    }
    return matching >= 6
  }

  private static func orderedUniqueEdits(_ a: [String], _ b: [String], shouldCancel: () -> Bool)
    -> (removed: Set<Int>, inserted: Set<Int>)? {
    // If every shared line occurs once on both sides and their order agrees,
    // every shared line belongs to the unique longest common subsequence.
    // All remaining lines must be removed/inserted, exactly as in the original
    // algorithm. Disjoint files are the zero-shared-line case. No heuristic
    // anchors, approximation, truncation or alternate ambiguous alignment.
    if a.isEmpty || b.isEmpty { return (Set(a.indices), Set(b.indices)) }
    var positions: [String: Int] = [:]
    positions.reserveCapacity(a.count)
    for i in a.indices {
      if i % 256 == 0 && shouldCancel() { return nil }
      if positions[a[i]] != nil { positions[a[i]] = -1 }
      else { positions[a[i]] = i }
    }
    var matchedA = Set<Int>(), matchedB = Set<Int>()
    var last = -1
    for j in b.indices {
      if j % 256 == 0 && shouldCancel() { return nil }
      guard let i = positions[b[j]] else { continue }
      guard i >= 0 && i > last else { return nil }
      last = i
      matchedA.insert(i); matchedB.insert(j)
    }
    return (Set(a.indices).subtracting(matchedA), Set(b.indices).subtracting(matchedB))
  }
}
