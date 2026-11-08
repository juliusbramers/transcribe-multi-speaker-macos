// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "tmsm",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "tmsm", targets: ["tmsm"]),
    .library(name: "TMSM", targets: ["TMSM"]),
  ],
  dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
  ],
  targets: [
    .target(
      name: "TMSM",
      dependencies: [
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .executableTarget(
      name: "tmsm",
      dependencies: [
        "TMSM",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      // Not Sources/tmsm: on the case-insensitive APFS default it is the same folder as Sources/TMSM.
      path: "Sources/CLI"
    ),
    .executableTarget(name: "selftest", dependencies: ["TMSM"]),
  ]
)
