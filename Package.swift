// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CadenzaKit",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17)],
    products: [
        .library(name: "CadenzaDomain", targets: ["CadenzaDomain"]),
        .library(name: "CadenzaKit", targets: ["CadenzaKit"]),
        .library(name: "CadenzaTesting", targets: ["CadenzaTesting"])
    ],
    targets: [
        .target(name: "CadenzaDomain"),
        .target(name: "CadenzaKit", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaTesting", dependencies: ["CadenzaDomain"]),
        .testTarget(name: "CadenzaKitTests", dependencies: ["CadenzaKit", "CadenzaTesting"])
    ]
)
