import Foundation
import GitDeskCore

// A dependency-free regression executable also runs with macOS Command Line
// Tools installations which do not include the XCTest framework.
class TestHarness {}
var failures: [String] = []
func record(_ message: String, _ file: StaticString, _ line: UInt) {
  let value = "\(file):\(line): \(message)"
  failures.append(value)
  print("FAIL " + value)
}
func XCTAssertEqual<T: Equatable>(
  _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
  file: StaticString = #filePath, line: UInt = #line
) {
  do {
    let x = try a()
    let y = try b()
    if x != y { record("\(x) != \(y)", file, line) }
  } catch { record(error.localizedDescription, file, line) }
}
func XCTAssertNotEqual<T: Equatable>(
  _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
  file: StaticString = #filePath, line: UInt = #line
) {
  do { if try a() == b() { record("Values are equal", file, line) } } catch {
    record(error.localizedDescription, file, line)
  }
}
func XCTAssertTrue(
  _ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line
) {
  do { if try !value() { record("Expected true", file, line) } } catch {
    record(error.localizedDescription, file, line)
  }
}
func XCTAssertFalse(
  _ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line
) { XCTAssertTrue(try !value(), file: file, line: line) }
func XCTAssertNil<T>(
  _ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line
) {
  do { if try value() != nil { record("Expected nil", file, line) } } catch {
    record(error.localizedDescription, file, line)
  }
}
func XCTAssertThrowsError<T>(
  _ value: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line
) {
  do {
    _ = try value()
    record("Expected error", file, line)
  } catch {}
}
func XCTUnwrap<T>(_ value: @autoclosure () throws -> T?) throws -> T {
  guard let value = try value() else { throw GitFailure("Unexpected nil") }
  return value
}

let cases: [(String, (GitRepositoryTests) throws -> Void)] = [
  ("Undo and reword preserve local changes", { try $0.testUndoAndRewordPreserveLocalChanges() }),
  ("Undo root and history guards", { try $0.testUndoRootAndHistoryGuards() }),
  ("Revision tree and patch round trip", { try $0.testRevisionTreeAndPatch() }),
  ("Rebase reorder, reword and drop", { try $0.testRebaseReorderRewordAndDrop() }),
  ("Rebase squash, fixup and root", { try $0.testRebaseSquashFixupAndRoot() }),
  ("Rebase conflict recovery", { try $0.testRebaseConflictRecovery() }),
  ("Automatic squash, drop all and stale session", { try $0.testAutomaticSquashDropAllAndStaleSession() }),
  ("History plan validation and navigation", { try $0.testHistoryPlanValidationAndNavigation() }),
  ("Unborn repository and initial commit", { try $0.testUnbornRepositoryAndInitialCommit() }),
  ("Selected commit preserves staging", { try $0.testSelectedCommitPreservesUnrelatedStaging() }),
  ("Failed commit preserves index", { try $0.testFailedCommitPreservesIndexAndWorkingTree() }),
  (
    "Amend preserves unrelated staging",
    { try $0.testAmendWithoutChangesPreservesUnrelatedStagedFiles() }
  ),
  ("NUL paths, Unicode and pathspecs", { try $0.testNulPathsUnicodeAndLiteralPathspecs() }),
  ("Symlinks and preview limits", { try $0.testSymlinkAndPreviewLimits() }),
  ("Rename parsing and commit", { try $0.testRenameParsingAndSelectedRenameCommit() }),
  ("Index and working diff", { try $0.testIndexAndWorkingDiff() }),
  ("Log filters", { try $0.testLogMessageRegexCaseAuthorPathAndBranchFilters() }),
  ("Filtered snapshot preserves state", { try $0.testFilteredSnapshotPreservesRepositoryState() }),
  ("Branch and tag checkout", { try $0.testBranchAndTagCheckout() }),
  ("Stash and restore", { try $0.testStashAndRestore() }),
  ("Push, fetch and pull via local remote", { try $0.testLocalRemotePushFetchPull() }),
  ("Conflicts and abort", { try $0.testConflictDetectionStagesAndAbort() }),
  ("Merge commit and untracked files", { try $0.testMergeCommitKeepsParentsAndUntrackedFiles() }),
  ("Rebase, worktree and annotated tag", { try $0.testRebaseWorktreeAndAnnotatedTag() }),
  ("Cherry-pick, revert and reset", { try $0.testCherryPickRevertAndReset() }),
  ("Discard and unstage", { try $0.testDiscardAndUnstage() }),
]
for (name, body) in cases {
  let test = GitRepositoryTests()
  let start = failures.count
  do {
    try test.setUpWithError()
    try body(test)
  } catch { record(error.localizedDescription, #filePath, #line) }
  do { try test.tearDownWithError() } catch { record(error.localizedDescription, #filePath, #line) }
  print((failures.count == start ? "PASS " : "FAIL ") + name)
}
let diffCases: [(String, () -> Void)] = [
  ("Filtered graph ancestry", { DiffAndGraphTests().testFilteredGraphProjectsHiddenAncestors() }),
  ("Line alignment", { DiffAndGraphTests().testLineAlignmentAndNumbers() }),
  ("Deleted and empty files", { DiffAndGraphTests().testDeletionAndEmptyFiles() }),
  (
    "Binary, whitespace and final newline",
    { DiffAndGraphTests().testBinaryWhitespaceAndFinalNewline() }
  ), ("Merge graph lanes", { DiffAndGraphTests().testMergeGraphLanesAndConvergence() }),
]
for (name, body) in diffCases {
  let start = failures.count
  body()
  print((failures.count == start ? "PASS " : "FAIL ") + name)
}
print("\(cases.count + diffCases.count) scenarios, \(failures.count) failures")
exit(failures.isEmpty ? 0 : 1)
