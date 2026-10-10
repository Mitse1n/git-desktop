import AppKit

let artworkURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("assets/AppIcon.png")
guard let artwork = NSImage(contentsOf: artworkURL) else {
  fatalError("Cannot load app icon artwork at \(artworkURL.path)")
}
// The approved artwork includes presentation margins around the white tile.
// Crop those margins and apply a clean transparent app-icon silhouette at every size.
let artworkRect = NSRect(
  x: artwork.size.width * 114 / 1254,
  y: artwork.size.height * 121 / 1254,
  width: artwork.size.width * 1025 / 1254,
  height: artwork.size.height * 1020 / 1254)

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
  NSGraphicsContext.current?.imageInterpolation = .high
  let dimension = CGFloat(pixels)
  let tile = NSRect(
    x: dimension * 0.07, y: dimension * 0.07, width: dimension * 0.86, height: dimension * 0.86)
  NSBezierPath(roundedRect: tile, xRadius: dimension * 0.18, yRadius: dimension * 0.18).addClip()
  artwork.draw(in: tile, from: artworkRect, operation: .sourceOver, fraction: 1)
  NSGraphicsContext.restoreGraphicsState()
  try bitmap.representation(using: .png, properties: [:])!.write(
    to: destination.appendingPathComponent(name))
}
