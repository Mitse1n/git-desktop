import AppKit

/// File types are resolved from names rather than the working tree, so deleted,
/// renamed and historical files retain their language icons.
enum FileTypeIcons {
  private static var cache: [String: NSImage] = [:]
  private static let extensions: [String: String] = [
    "swift": "swiftLang", "md": "markdown", "markdown": "markdown", "mdx": "markdown",
    "go": "go", "py": "python", "pyi": "python", "java": "java",
    "c": "c", "m": "c", "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "mm": "cpp", "h": "h", "hpp": "h",
    "js": "javaScript", "jsx": "javaScript", "mjs": "javaScript", "cjs": "javaScript",
    "ts": "typeScript", "tsx": "typeScript", "css": "css", "scss": "css", "less": "css",
    "html": "html", "htm": "html", "json": "json", "jsonc": "json", "xml": "xml", "svg": "xml",
    "yaml": "yaml", "yml": "yaml", "toml": "toml", "sh": "shell", "zsh": "shell", "bash": "shell",
    "sql": "sql", "properties": "properties", "ini": "config", "conf": "config", "cfg": "config",
    "txt": "text", "log": "text", "csv": "csv", "patch": "patch", "diff": "patch",
    "png": "image", "jpg": "image", "jpeg": "image", "gif": "image", "webp": "image", "ico": "image",
    "zip": "archive", "gz": "archive", "tar": "archive", "7z": "archive", "jar": "archive",
    "bin": "binaryData", "dat": "binaryData",
  ]
  static func assetName(for path: String) -> String {
    let name = (path as NSString).lastPathComponent.lowercased()
    if [".gitignore", ".gitattributes", ".gitmodules"].contains(name) { return "gitignore" }
    if name == ".editorconfig" { return "editorConfig" }
    if name == "dockerfile" || name.hasPrefix("dockerfile.") { return "docker" }
    if ["makefile", "cmakelists.txt", "package.swift"].contains(name) {
      return name == "package.swift" ? "swiftLang" : "config"
    }
    return extensions[(name as NSString).pathExtension] ?? "unknown"
  }
  static func image(for path: String) -> NSImage {
    let name = assetName(for: path)
    let key = name + (Theme.current.isDark ? "_dark" : "")
    if let image = cache[key] { return image }
    let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("assets/file-icons")
    let roots = [Bundle.main.resourceURL?.appendingPathComponent("FileIcons"), development].compactMap { $0 }
    for root in roots {
      for variant in [key, name] {
        if let image = NSImage(contentsOf: root.appendingPathComponent(variant + ".svg")) {
          image.size = NSSize(width: 16, height: 16)
          image.isTemplate = false
          cache[key] = image
          return image
        }
      }
    }
    return NSImage(systemSymbolName: "doc", accessibilityDescription: "File") ?? NSImage()
  }
}

final class FileTypeImageView: NSImageView, ThemeUpdating {
  let path: String
  init(path: String) {
    self.path = path
    super.init(frame: .zero)
    imageScaling = .scaleProportionallyUpOrDown
    setAccessibilityLabel(FileTypeIcons.assetName(for: path) + " file")
    refreshTheme()
  }
  required init?(coder: NSCoder) { fatalError() }
  func refreshTheme() {
    image = FileTypeIcons.image(for: path)
    contentTintColor = nil
    needsDisplay = true
  }
}
