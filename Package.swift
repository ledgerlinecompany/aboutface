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
  targets: [
    .target(
      name: "AboutFaceCore"
    ),
    .executableTarget(
      name: "aboutface-cli",
      dependencies: ["AboutFaceCore"]
    ),
    .testTarget(
      name: "AboutFaceCoreTests",
      dependencies: ["AboutFaceCore"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
