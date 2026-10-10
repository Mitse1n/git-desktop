import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var repositoryWindows: [RepositoryWindowController] = []
  private weak var activeRepositoryWindow: RepositoryWindowController?
  private var pendingOpenURL: URL?
  var controller: RepositoryController? {
    (activeRepositoryWindow ?? repositoryWindows.last)?.repositoryController
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    if let iconURL = Bundle.main.url(forResource: "GitDesk", withExtension: "icns"),
      let icon = NSImage(contentsOf: iconURL) {
      NSApp.applicationIconImage = icon
    }
    NSApp.appearance = NSAppearance(named: .darkAqua)
    makeMenu()
    newWindow()
    let args = CommandLine.arguments.dropFirst()
    if let pendingOpenURL {
      controller?.open(pendingOpenURL)
      self.pendingOpenURL = nil
    } else if let path = args.first(where: { !$0.hasPrefix("-") }) {
      controller?.open(URL(fileURLWithPath: path))
    } else if let path = UserDefaults.standard.string(forKey: "lastRepository"),
      FileManager.default.fileExists(atPath: path) {
      controller?.open(URL(fileURLWithPath: path))
    }
  }
  func newWindow() {
    let context = RepositoryWindowController()
    if let previous = activeRepositoryWindow?.window, let window = context.window {
      window.setFrameOrigin(NSPoint(x: previous.frame.minX + 24, y: previous.frame.minY - 24))
    }
    context.onActivate = { [weak self, weak context] in self?.activeRepositoryWindow = context }
    context.onClose = { [weak self, weak context] in
      guard let self else { return }
      self.repositoryWindows.removeAll { $0 === context }
      if self.activeRepositoryWindow === context {
        self.activeRepositoryWindow = self.repositoryWindows.last
      }
    }
    repositoryWindows.append(context)
    activeRepositoryWindow = context
    context.present()
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    if let path = filenames.first {
      let url = URL(fileURLWithPath: path)
      if repositoryWindows.isEmpty { pendingOpenURL = url }
      else {
        controller?.open(url)
        activeRepositoryWindow?.present()
      }
    }
    sender.reply(toOpenOrPrint: .success)
  }
  func makeMenu() {
    let main = NSMenu()
    let app = NSMenu()
    app.addItem(
      menuItem("About GitDesk") {
        let alert = NSAlert()
        alert.messageText = "GitDesk"
        alert.informativeText =
          "A native Swift + AppKit Git client inspired by IntelliJ IDEA.\nVersion 0.1.0"
        alert.runModal()
      })
    app.addItem(.separator())
    app.addItem(
      withTitle: "Hide GitDesk", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(.separator())
    app.addItem(
      withTitle: "Quit GitDesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    add("GitDesk", menu: app, to: main)
    let file = NSMenu()
    addAction(file, "New Window", key: "n") { [weak self] in self?.newWindow() }
    addAction(file, "Open Repository…", key: "o") { [weak self] in self?.controller?.openPanel() }
    addAction(file, "Clone Repository…") { [weak self] in self?.controller?.cloneRepository() }
    addAction(file, "New Repository…") { [weak self] in self?.controller?.initializeRepository() }
    file.addItem(.separator())
    file.addItem(
      withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    add("File", menu: file, to: main)
    let edit = NSMenu()
    for (title, selector, key) in [
      ("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"),
      ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
      ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ] { edit.addItem(withTitle: title, action: selector, keyEquivalent: key) }
    add("Edit", menu: edit, to: main)
    let git = NSMenu()
    addAction(git, "Commit…", key: "k") { [weak self] in self?.controller?.setMode("Commit") }
    addAction(git, "Push…", key: "k", modifiers: [.command, .shift]) { [weak self] in
      self?.controller?.push()
    }
    addAction(git, "Pull…", key: "t") { [weak self] in self?.controller?.remoteAction("pull") }
    addAction(git, "Fetch") { [weak self] in self?.controller?.remoteAction("fetch") }
    git.addItem(.separator())
    addAction(git, "Branches…") { [weak self] in self?.controller?.showBranchMenu() }
    addAction(git, "New Branch…", key: "n", modifiers: [.command, .option]) { [weak self] in
      self?.controller?.newBranch()
    }
    addAction(git, "Stash Changes…") { [weak self] in self?.controller?.stashChanges() }
    addAction(git, "Unstash Changes…") { [weak self] in self?.controller?.showStashes() }
    addAction(git, "Manage Remotes…") { [weak self] in self?.controller?.manageRemotes() }
    add("Git", menu: git, to: main)
    let view = NSMenu()
    addAction(view, "Git Log", key: "1") { [weak self] in self?.controller?.setMode("Log") }
    addAction(view, "Console", key: "2") { [weak self] in self?.controller?.setMode("Console") }
    addAction(view, "Refresh", key: "r") { [weak self] in self?.controller?.refresh() }
    addAction(view, "Filter by Text or Hash", key: "l") { [weak self] in
      self?.controller?.focusSearch()
    }
    addAction(view, "Go to Hash / Branch / Tag…", key: "f") { [weak self] in self?.controller?.goTo()
    }
    addAction(view, "Show Diff", key: "d") { [weak self] in self?.controller?.showDiff() }
    addAction(view, "Show / Hide Branches") { [weak self] in self?.controller?.toggleBranches() }
    add("View", menu: view, to: main)
    let windows = NSMenu()
    windows.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windows.addItem(
      withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    add("Window", menu: windows, to: main)
    NSApp.windowsMenu = windows
    NSApp.mainMenu = main
  }
  func add(_ title: String, menu: NSMenu, to main: NSMenu) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = menu
    main.addItem(item)
  }
  func addAction(
    _ menu: NSMenu, _ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
    handler: @escaping () -> Void
  ) {
    let item = menuItem(title, handler: handler)
    item.keyEquivalent = key
    item.keyEquivalentModifierMask = modifiers
    menu.addItem(item)
  }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
