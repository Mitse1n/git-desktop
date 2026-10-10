import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
  ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in sizes {
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  let dimension = CGFloat(pixels)
  let tile = NSRect(
    x: dimension * 0.07, y: dimension * 0.07, width: dimension * 0.86, height: dimension * 0.86)
  NSColor(srgbRed: 0.15, green: 0.16, blue: 0.18, alpha: 1).setFill()
  NSBezierPath(roundedRect: tile, xRadius: dimension * 0.18, yRadius: dimension * 0.18).fill()
  let configuration = NSImage.SymbolConfiguration(pointSize: dimension * 0.5, weight: .regular)
    .applying(.init(paletteColors: [NSColor(srgbRed: 0.42, green: 0.62, blue: 0.98, alpha: 1)]))
  let symbol = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)!
    .withSymbolConfiguration(configuration)!
  symbol.draw(
    in: NSRect(
      x: dimension * 0.28, y: dimension * 0.25, width: dimension * 0.44, height: dimension * 0.50))
  NSGraphicsContext.restoreGraphicsState()
  try bitmap.representation(using: .png, properties: [:])!.write(
    to: destination.appendingPathComponent(name))
}
