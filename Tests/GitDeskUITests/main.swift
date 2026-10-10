import AppKit

// Exercise the real console storage without opening a window or changing a repo.
let console = ConsoleTextView()
console.isHidden = true
precondition(console.textLayoutManager == nil)
let large = String(repeating: "history\0中文🙂\n", count: 100_000)
let preview = ConsoleTextView.preview(large)
precondition(preview.utf16.count <= ConsoleTextView.entryLimit + 40)
precondition(preview.contains("[Output truncated in Console]"))
precondition(!preview.contains("\0"))
let start = Date()
for _ in 0..<100 {
  console.appendEntry(large, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
  precondition(console.textStorage!.length <= ConsoleTextView.storageLimit)
  precondition(!console.string.contains("�"))
}
console.appendEntry("最新输出🙂\nExit code: 1\n", attributes: [:])
precondition(console.string.hasSuffix("最新输出🙂\nExit code: 1\n"))
console.string = large
console.appendEntry("git log\n" + preview + "\nExit code: 1\n", attributes: [:])
precondition(console.textStorage!.length <= ConsoleTextView.storageLimit)
precondition(console.string.hasSuffix("Exit code: 1\n"))
precondition(console.string.contains("[Output truncated in Console]"))
console.string = ""
precondition(console.textStorage!.length == 0)
print("Console oversized/Unicode/binary/repeated-output checks passed (\(String(format: "%.3f", Date().timeIntervalSince(start)))s)")
