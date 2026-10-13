import AppKit

// Git's machine-readable output can contain NULs and megabytes of history.
// Bound it before dispatching to the main thread, independently of Git's result.
final class ConsoleTextView: NSTextView {
  nonisolated static let entryLimit = 20_000
  nonisolated static let storageLimit = 200_000

  init() {
    // A bounded append-only console does not need TextKit 2 viewport estimation.
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer()
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    super.init(frame: .zero, textContainer: container)
  }
  required init?(coder: NSCoder) { fatalError() }

  nonisolated static func preview(_ output: String, limit: Int = entryLimit) -> String {
    var result = ""
    var length = 0
    for scalar in output.unicodeScalars {
      let width = scalar.value > 0xFFFF ? 2 : 1
      if length + width > limit {
        result += "\n[Output truncated in Console]\n"
        break
      }
      // Keep line breaks and tabs; binary separators are not display text.
      if scalar.value < 32 && scalar != "\n" && scalar != "\t" {
        result += " "
      } else {
        result.unicodeScalars.append(scalar)
      }
      length += width
    }
    return result
  }

  func appendEntry(_ entry: String, attributes: [NSAttributedString.Key: Any]) {
    guard let storage = textStorage else { return }
    // Leave room for the timestamp, command and exit status around the preview.
    let incoming = NSAttributedString(
      string: Self.preview(entry, limit: Self.entryLimit + 4096), attributes: attributes)
    storage.beginEditing()
    let excess = max(0, storage.length + incoming.length - Self.storageLimit)
    if excess > 0 {
      // NSTextStorage ranges are UTF-16, unlike Swift String.count. Include the
      // whole boundary character so truncation cannot leave a split surrogate.
      let range = (storage.string as NSString).rangeOfComposedCharacterSequences(
        for: NSRange(location: 0, length: min(excess, storage.length)))
      storage.deleteCharacters(in: range)
    }
    storage.append(incoming)
    storage.endEditing()
    if !isHiddenOrHasHiddenAncestor, window != nil {
      scrollToEndOfDocument(nil)
    }
  }
}
