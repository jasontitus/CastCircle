// swift-tools-version: 6.0
// macOS verification harness for the vendored Kokoro/Misaki MLX code.
// Symlinks the app's iOS sources so any edit there is compiled and run
// here directly — prove correctness on the Mac before any phone round-trip.
import PackageDescription

let package = Package(
    name: "mlx-harness",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.29.1"),
        .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", from: "0.0.6"),
    ],
    targets: [
        .executableTarget(
            name: "harness",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
