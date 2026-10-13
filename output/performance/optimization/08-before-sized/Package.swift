// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "GitDesk", platforms: [.macOS(.v14)],
  products: [.executable(name: "GitDesk", targets: ["GitDesk"])],
  targets: [
    .target(name: "GitDeskCore"), .executableTarget(name: "GitDesk", dependencies: ["GitDeskCore"]),
    .executableTarget(
      name: "GitDeskChecks", dependencies: ["GitDeskCore"], path: "Tests/GitDeskCoreTests"),
  ], swiftLanguageModes: [.v5])
