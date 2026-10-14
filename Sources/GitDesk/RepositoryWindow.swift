import AppKit

final class RepositoryWindowController: NSWindowController, NSWindowDelegate {
  let repositoryController = RepositoryController()
  var onActivate: (() -> Void)?
  var onClose: (() -> Void)?
  private let titlebarControls = NSTitlebarAccessoryViewController()
  private let titlebarLeading: CGFloat = 93
  private let titlebarCenter: CGFloat = 21

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1440, height: 850),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "GitDesk"
    window.tabbingMode = .disallowed
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
    window.contentViewController = repositoryController
    titlebarControls.layoutAttribute = .right
    titlebarControls.view = RepositoryTitlebarAccessoryView(controls: repositoryController.headerControls,
      width: window.frame.width - titlebarLeading)
    window.addTitlebarAccessoryViewController(titlebarControls)
    window.setFrameAutosaveName("MainWindow")
    window.center()
  }
  required init?(coder: NSCoder) { fatalError() }

  func present() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    positionWindowControls()
    DispatchQueue.main.async { [weak self] in self?.positionWindowControls() }
    NSApp.activate(ignoringOtherApps: true)
  }
  func windowDidBecomeMain(_ notification: Notification) { onActivate?() }
  func windowDidResize(_ notification: Notification) {
    guard let window else { return }
    titlebarControls.view.setFrameSize(NSSize(width: max(0, window.frame.width - titlebarLeading), height: 42))
    positionWindowControls()
    DispatchQueue.main.async { [weak self] in self?.positionWindowControls() }
  }
  private func positionWindowControls() {
    guard let window, let content = window.contentView else { return }
    for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
      guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
      let point = NSPoint(x: 8 + CGFloat(index) * 20,
        y: content.bounds.height - titlebarCenter - button.frame.height / 2)
      button.setFrameOrigin(parent.convert(point, from: content))
    }
    titlebarControls.view.needsLayout = true
    titlebarControls.view.layoutSubtreeIfNeeded()
  }
  func windowWillClose(_ notification: Notification) {
    repositoryController.watcher?.invalidate()
    repositoryController.terminalWorkspace.shutdown()
    repositoryController.diffWindows.forEach { $0.close() }
    repositoryController.conflictWindows.forEach { $0.close() }
    repositoryController.revisionWindows.forEach { $0.close() }
    onClose?()
  }
}
