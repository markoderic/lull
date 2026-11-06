// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lull",
    platforms: [.macOS("15.4")],
    products: [
        .executable(name: "Lull", targets: ["Lull"]),
    ],
    targets: [
        .target(name: "LullCore"),
        .executableTarget(name: "Lull", dependencies: ["LullCore"]),
        .testTarget(name: "LullCoreTests", dependencies: ["LullCore"]),
    ]
)
