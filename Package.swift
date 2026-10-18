// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Burrow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Burrow", targets: ["Burrow"]),
        .executable(name: "burrowctl", targets: ["burrowctl"]),
        .library(name: "BurrowCore", targets: ["BurrowCore"]),
    ],
    targets: [
        .target(name: "BurrowCore"),
        .executableTarget(name: "Burrow", dependencies: ["BurrowCore"]),
        .executableTarget(name: "burrowctl", dependencies: ["BurrowCore"]),
        .testTarget(name: "BurrowCoreTests", dependencies: ["BurrowCore"]),
    ],
    swiftLanguageModes: [.v5]
)
