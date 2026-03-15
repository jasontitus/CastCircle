// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ParakeetSTT",
    platforms: [
        .iOS(.v18), .macOS(.v15)
    ],
    products: [
        .library(
            name: "ParakeetSTT",
            targets: ["ParakeetSTT"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.29.1"),
    ],
    targets: [
        .target(
            name: "ParakeetSTT",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
            ]
        ),
    ]
)
