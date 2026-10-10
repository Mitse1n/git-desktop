import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  var window: NSWindow!
  let controller = RepositoryController()
  var titlebarControls: NSTitlebarAccessoryViewController!
  func applicationDidFinishLaunching(_ notification: Notification) {
    if let iconURL = Bundle.main.url(forResource: "GitDesk", withExtension: "icns"),
      let icon = NSImage(contentsOf: iconURL)
    {
      NSApp.applicationIconImage = icon
    }
    NSApp.appearance = NSAppearance(named: .darkAqua)
    makeMenu()
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1440, height: 850),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false
    )
    window.title = "GitDesk"
    window.minSize = NSSize(width: 1120, height: 620)
    window.backgroundColor = Theme.chrome
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    let toolbar = NSToolbar(identifier: "RepositoryHeader")
    toolbar.displayMode = .iconOnly
    toolbar.showsBaselineSeparator = false
    window.toolbarStyle = .unifiedCompact
    window.toolbar = toolbar
    window.titlebarSeparatorStyle = .none
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    titlebarControls = NSTitlebarAccessoryViewController()
    titlebarControls.layoutAttribute = .right
    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: window.frame.width - 87, height: 42))
    titlebarControls.view = accessory
    accessory.addSubview(controller.headerControls)
    NSLayoutConstraint.activate([
      controller.headerControls.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
      controller.headerControls.trailingAnchor.constraint(equalTo: accessory.trailingAnchor, constant: -14),
      controller.headerControls.topAnchor.constraint(equalTo: accessory.topAnchor),
      controller.headerControls.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
    ])
    window.addTitlebarAccessoryViewController(titlebarControls)
    window.setFrameAutosaveName("MainWindow")
    window.center()
    window.makeKeyAndOrderFront(nil)
    positionWindowControls()
    NSApp.activate(ignoringOtherApps: true)
    let args = CommandLine.arguments.dropFirst()
    if let path = args.first(where: { !$0.hasPrefix("-") }) {
      controller.open(URL(fileURLWithPath: path))
    } else if let path = UserDefaults.standard.string(forKey: "lastRepository"),
      FileManager.default.fileExists(atPath: path)
    {
      controller.open(URL(fileURLWithPath: path))
    }
  }
  func windowDidResize(_ notification: Notification) {
    titlebarControls?.view.setFrameSize(NSSize(width: max(0, window.frame.width - 87), height: 42))
    positionWindowControls()
  }
  func positionWindowControls() {
    guard let content = window.contentView else { return }
    for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
      .enumerated()
    {
      guard let button = window.standardWindowButton(type), let parent = button.superview else {
        continue
      }
      let point = NSPoint(
        x: 8 + CGFloat(index) * 20,
        y: content.bounds.height - 21 - button.frame.height / 2)
      button.setFrameOrigin(parent.convert(point, from: content))
    }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    if let path = filenames.first { controller.open(URL(fileURLWithPath: path)) }
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
    addAction(file, "Open Repository…", key: "o") { [weak self] in self?.controller.openPanel() }
    addAction(file, "Clone Repository…") { [weak self] in self?.controller.cloneRepository() }
    addAction(file, "New Repository…") { [weak self] in self?.controller.initializeRepository() }
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
    addAction(git, "Commit…", key: "k") { [weak self] in self?.controller.setMode("Commit") }
    addAction(git, "Push…", key: "k", modifiers: [.command, .shift]) { [weak self] in
      self?.controller.push()
    }
    addAction(git, "Pull…", key: "t") { [weak self] in self?.controller.remoteAction("pull") }
    addAction(git, "Fetch") { [weak self] in self?.controller.remoteAction("fetch") }
    git.addItem(.separator())
    addAction(git, "Branches…") { [weak self] in self?.controller.showBranchMenu() }
    addAction(git, "New Branch…", key: "n", modifiers: [.command, .option]) { [weak self] in
      self?.controller.newBranch()
    }
    addAction(git, "Stash Changes…") { [weak self] in self?.controller.stashChanges() }
    addAction(git, "Unstash Changes…") { [weak self] in self?.controller.showStashes() }
    addAction(git, "Manage Remotes…") { [weak self] in self?.controller.manageRemotes() }
    add("Git", menu: git, to: main)
    let view = NSMenu()
    addAction(view, "Git Log", key: "1") { [weak self] in self?.controller.setMode("Log") }
    addAction(view, "Console", key: "2") { [weak self] in self?.controller.setMode("Console") }
    addAction(view, "Refresh", key: "r") { [weak self] in self?.controller.refresh() }
    addAction(view, "Filter by Text or Hash", key: "l") { [weak self] in
      self?.controller.focusSearch()
    }
    addAction(view, "Go to Hash / Branch / Tag…", key: "f") { [weak self] in self?.controller.goTo()
    }
    addAction(view, "Show Diff", key: "d") { [weak self] in self?.controller.showDiff() }
    addAction(view, "Show / Hide Branches") { [weak self] in self?.controller.toggleBranches() }
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
