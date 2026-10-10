import AppKit
import GitDeskCore

enum CommitDetails {
  static func text(for commit: Commit) -> NSAttributedString {
    let messageFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let result = NSMutableAttributedString(string: commit.subject,
      attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
        .foregroundColor: Theme.text])
    func append(_ text: String, font: NSFont = Theme.font) {
      result.append(NSAttributedString(string: text,
        attributes: [.font: font, .foregroundColor: Theme.text]))
    }
    if !commit.body.isEmpty { append("\n\n" + commit.body, font: messageFont) }
    append("\n\n\(commit.shortHash) \(commit.author)")
    if !commit.email.isEmpty {
      append(" ")
      let email = "<\(commit.email)>"
      var attributes: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: Theme.blue]
      if let url = URL(string: "mailto:" + commit.email) { attributes[.link] = url }
      result.append(NSAttributedString(string: email, attributes: attributes))
    }
    append(" on \(commit.date.formatted())")
    if !commit.decorations.isEmpty { append("\n\n" + commit.decorations.joined(separator: "   ")) }
    return result
  }
}
