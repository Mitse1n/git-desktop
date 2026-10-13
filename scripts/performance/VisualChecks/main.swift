import AppKit
import CryptoKit
import GitDeskCore

// Compile this same renderer against frozen-before and current application
// sources. It renders AppKit views, not desktop screenshots or simulated UI.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
func pump(_ ready: () -> Bool) {
  let deadline = Date().addingTimeInterval(60)
  while !ready() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
  precondition(ready())
}
func drain(_ queue: DispatchQueue) {
  for _ in 0..<2 {
    var done = false
    queue.async { DispatchQueue.main.async { done = true } }
    pump { done }
  }
}
var images: [[String: Any]] = []
func normalizeFlexibleOptionSpacing(_ view: NSView, search: NSSearchField) {
  if let stack = view as? NSStackView, stack.arrangedSubviews.count == 6,
    stack.arrangedSubviews.contains(where: { $0 === search }) {
    // The original row has two equally flexible empty views. Its solver can
    // place all spare width on either side even across two original-only runs.
    // Fix this undefined allocation equally in both test builds, without
    // changing production constraints or normalizing any content/control size.
    stack.arrangedSubviews[1].widthAnchor.constraint(equalToConstant: 0).isActive = true
  }
  view.subviews.forEach { normalizeFlexibleOptionSpacing($0, search: search) }
}
func render(_ view: NSView, _ name: String) throws {
  view.layoutSubtreeIfNeeded()
  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
  view.cacheDisplay(in: view.bounds, to: bitmap)
  let png = bitmap.representation(using: .png, properties: [:])!
  try png.write(to: output.appendingPathComponent(name + ".png"))
  // Hash actual pixels, excluding any alignment padding at the end of rows.
  var pixels = Data()
  let rowBytes = bitmap.pixelsWide * bitmap.bitsPerPixel / 8
  for y in 0..<bitmap.pixelsHigh {
    pixels.append(bitmap.bitmapData!.advanced(by: y * bitmap.bytesPerRow), count: rowBytes)
  }
  images.append(["name": name, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh,
    "bytes_per_row": bitmap.bytesPerRow, "bits_per_pixel": bitmap.bitsPerPixel,
    "pixel_sha256": SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()])
}
func window(_ controller: NSViewController) -> NSWindow {
  let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1440, height: 850),
    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentViewController = controller
  NSLayoutConstraint.activate([controller.view.widthAnchor.constraint(equalToConstant: 1440),
    controller.view.heightAnchor.constraint(equalToConstant: 850)])
  window.setContentSize(NSSize(width: 1440, height: 850))
  controller.view.setFrameSize(NSSize(width: 1440, height: 850))
  controller.view.layoutSubtreeIfNeeded()
  precondition(controller.view.bounds.size == NSSize(width: 1440, height: 850))
  controller.viewDidAppear()
  if let repository = controller as? RepositoryController {
    repository.split.adjustSubviews()
    repository.view.layoutSubtreeIfNeeded()
    repository.detailsSplit?.adjustSubviews()
    if let details = repository.detailsSplit { details.setPosition(details.bounds.height * 0.64, ofDividerAt: 0) }
    repository.view.layoutSubtreeIfNeeded()
    precondition(repository.split.subviews.first!.frame.width > 100
      && repository.split.subviews.last!.frame.width > 100)
  }
  return window
}
let themes = CommandLine.arguments.count > 3 ? [AppTheme(rawValue: CommandLine.arguments[3])!] : AppTheme.allCases
for theme in themes {
  try autoreleasepool {
    Theme.current = theme
    NSApp.appearance = theme.appearance
    let controller = RepositoryController()
    let logWindow = window(controller)
    logWindow.appearance = theme.appearance
    _ = controller.view
    controller.watcher?.invalidate()
    controller.open(root)
    pump { !controller.isBusy }
    precondition(controller.snapshot != nil)
    controller.logTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    drain(controller.queue)
    Theme.refresh(controller.view)
    try render(controller.view, theme.rawValue + "-log")
    let viewer = DiffViewController()
    let diffWindow = window(viewer)
    diffWindow.appearance = theme.appearance
    normalizeFlexibleOptionSpacing(viewer.view, search: viewer.search)
    let paths = ["diff.txt"] + (FileManager.default.fileExists(atPath: root.appendingPathComponent("syntax.swift").path) ? ["syntax.swift"] : [])
    for path in paths {
      viewer.load(repository: controller.repository!, change: FileChange(path: path, index: " ", worktree: "M"))
      pump { viewer.diff != nil }
      for layout in [0, 1] {
        viewer.layoutToggle.selectedSegment = layout
        viewer.optionsChanged(); drain(viewer.queue)
        viewer.navigate(1)
        Theme.refresh(viewer.view)
        try render(viewer.view, theme.rawValue + (path == "syntax.swift" ? "-swift" : "") + (layout == 0 ? "-split" : "-unified"))
      }
    }
    logWindow.close(); diffWindow.close()
  }
}
try JSONSerialization.data(withJSONObject: images, options: [.prettyPrinted, .sortedKeys])
  .write(to: output.appendingPathComponent("manifest.json"))
print("Rendered \(images.count) AppKit views")
