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
    // MLX speech models (Qwen3-ASR, Voxtral Mini, MOSS-Transcribe-Diarize, Qwen3 forced aligner).
    .package(url: "https://github.com/soniqo/speech-swift.git", exact: "0.0.29"),
    // Already a dependency of speech-swift; named here only to free MLX's buffer cache.
    .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.30.0"),
  ],
  targets: [
    .target(
      name: "TMSM",
      dependencies: [
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Qwen3ASR", package: "speech-swift"),
        .product(name: "VoxtralASR", package: "speech-swift"),
        .product(name: "MossTranscribe", package: "speech-swift"),
        .product(name: "AudioCommon", package: "speech-swift"),
        .product(name: "MLX", package: "mlx-swift"),
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
