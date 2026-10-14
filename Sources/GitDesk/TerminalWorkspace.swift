import AppKit
import SwiftTerm

final class TerminalWorkspace: NSView, ThemeUpdating, LocalProcessTerminalViewDelegate {
  private struct Session {
    let id: UUID
    let root: URL
    let terminal: LocalProcessTerminalView
    var title: String
    var exited = false
  }
  private var sessions: [Session] = []
  private let picker = NSPopUpButton()
  private let body = NSView()
  private let hint = label("Open a terminal session in your repository.", color: Theme.muted)
  private var active: Int? { picker.indexOfSelectedItem >= 0 && picker.indexOfSelectedItem < sessions.count ? picker.indexOfSelectedItem : nil }
  var repositoryURL: URL?
  var sessionCount: Int { sessions.count }
  var activeTerminal: LocalProcessTerminalView? { active.map { sessions[$0].terminal } }
  override init(frame: NSRect) {
    super.init(frame: frame)
    picker.target = self; picker.action = #selector(selectSession)
    picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    let toolbar = row([picker, ActionButton(symbol: "plus", tooltip: "New Terminal Session") { [weak self] in self?.newSession() },
      ActionButton(symbol: "xmark", tooltip: "Close Terminal Session") { [weak self] in self?.closeSession() },
      NSView(), label("Interactive shell · repository working directory", color: Theme.muted, size: 11)])
    pin(makePanel(toolbar, body: body), to: self)
    showHint()
  }
  required init?(coder: NSCoder) { fatalError() }
  private func showHint() {
    // A label pinned to all four edges gives the entire window its vertical
    // hugging constraint, even when this workspace is hidden behind Log.
    hint.translatesAutoresizingMaskIntoConstraints = false
    body.addSubview(hint)
    NSLayoutConstraint.activate([
      hint.centerXAnchor.constraint(equalTo: body.centerXAnchor),
      hint.centerYAnchor.constraint(equalTo: body.centerYAnchor),
      hint.leadingAnchor.constraint(greaterThanOrEqualTo: body.leadingAnchor, constant: 16),
      hint.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor, constant: -16),
    ])
  }
  func activate(at url: URL?) {
    repositoryURL = url
    let root = url ?? FileManager.default.homeDirectoryForCurrentUser
    if let existing = sessions.firstIndex(where: { $0.root == root && !$0.exited }) {
      picker.selectItem(at: existing); selectSession()
    } else { newSession() }
  }
  func newSession(executable: String? = nil, arguments: [String] = ["-l"]) {
    let root = repositoryURL ?? FileManager.default.homeDirectoryForCurrentUser
    let terminal = LocalProcessTerminalView(frame: body.bounds)
    terminal.processDelegate = self
    terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    let number = sessions.count + 1
    sessions.append(Session(id: UUID(), root: root, terminal: terminal, title: "\(number): \(root.lastPathComponent)"))
    picker.addItem(withTitle: sessions.last!.title)
    picker.selectItem(at: sessions.count - 1)
    selectSession(); refreshTheme()
    let configured = executable ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let shell = FileManager.default.isExecutableFile(atPath: configured) ? configured : "/bin/zsh"
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"; environment["COLORTERM"] = "truecolor"
    terminal.startProcess(executable: shell, args: arguments, environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: root.path)
    window?.makeFirstResponder(terminal)
  }
  @objc private func selectSession() {
    body.subviews.forEach { $0.removeFromSuperview() }
    guard let active else { showHint(); return }
    pin(sessions[active].terminal, to: body)
    body.layoutSubtreeIfNeeded()
    window?.makeFirstResponder(sessions[active].terminal)
  }
  private func closeSession() {
    guard let active else { return }
    if !sessions[active].exited {
      let alert = NSAlert(); alert.messageText = "Close Terminal Session?"
      alert.informativeText = "The shell and processes in this session will be terminated."
      alert.addButton(withTitle: "Close Session"); alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    let session = sessions.remove(at: active)
    session.terminal.processDelegate = nil; session.terminal.terminate()
    picker.removeItem(at: active); selectSession()
  }
  func shutdown() {
    for session in sessions { session.terminal.processDelegate = nil; session.terminal.terminate() }
    sessions.removeAll()
  }
  func refreshTheme() {
    for session in sessions {
      session.terminal.nativeBackgroundColor = Theme.background
      session.terminal.nativeForegroundColor = Theme.text
      session.terminal.caretColor = Theme.text
      session.terminal.selectedTextBackgroundColor = Theme.activeSelection
    }
  }
  func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
  func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    guard let index = sessions.firstIndex(where: { $0.terminal === source }) else { return }
    picker.item(at: index)?.title = "\(index + 1): " + String(title.prefix(100))
  }
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  func processTerminated(source: TerminalView, exitCode: Int32?) {
    guard let index = sessions.firstIndex(where: { $0.terminal === source }) else { return }
    sessions[index].exited = true
    picker.item(at: index)?.title = sessions[index].title + " (exited)"
  }
}
