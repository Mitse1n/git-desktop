// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "GitDesk", platforms: [.macOS(.v14)],
  products: [.executable(name: "GitDesk", targets: ["GitDesk"])],
  dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
  targets: [
    .target(name: "GitDeskCore"), .executableTarget(name: "GitDesk", dependencies: ["GitDeskCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
    .executableTarget(
      name: "GitDeskChecks", dependencies: ["GitDeskCore"], path: "Tests/GitDeskCoreTests"),
  ], swiftLanguageModes: [.v5])
