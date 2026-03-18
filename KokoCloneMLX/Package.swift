// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KokoCloneMLX",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "KokoCloneMLX", targets: ["KokoCloneMLX"]),
        .executable(name: "kokoclone-test", targets: ["KokoCloneTest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.21.0"),
    ],
    targets: [
        .target(
            name: "KokoCloneMLX",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "KokoCloneTest",
            dependencies: ["KokoCloneMLX"]
        ),
    ]
)
