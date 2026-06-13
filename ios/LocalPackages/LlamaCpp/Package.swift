// swift-tools-version: 5.10
import PackageDescription

// Vendored wrapper around the prebuilt llama.cpp xcframework so the Runner can
// link it via a local SwiftPM reference. The xcframework is fetched from a
// pinned ggml-org/llama.cpp GitHub release (b8777 — first stable build with
// Gemma 4 support, also the build the public gemma4-iphone-demo pins). The
// binary target's module is `llama`, exposing the full C `llama.h` API to Swift.
let package = Package(
    name: "LlamaCpp",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LlamaCpp", targets: ["llama"])
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b8777/llama-b8777-xcframework.zip",
            checksum: "a983728bb037535226f7d17a12ac0efcf75547a7084d0e23933caf0ec3bcfe5c"
        )
    ]
)
