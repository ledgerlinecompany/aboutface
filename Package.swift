// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AboutFace",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(
      name: "AboutFaceCore",
      targets: ["AboutFaceCore"]
    ),
    .executable(
      name: "aboutface-cli",
      targets: ["aboutface-cli"]
    ),
  ],
  dependencies: [
    // CLI-only dependency (see the `aboutface-cli` target below). The core
    // library, `AboutFaceCore`, stays dependency-free — this must never be
    // added to its `dependencies:` list.
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
  ],
  targets: [
    .target(
      name: "AboutFaceCore"
    ),
    .executableTarget(
      name: "aboutface-cli",
      dependencies: [
        "AboutFaceCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(
      name: "AboutFaceCoreTests",
      dependencies: ["AboutFaceCore"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
