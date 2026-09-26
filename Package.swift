// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CadenzaKit",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17)],
    products: [
        .library(name: "CadenzaDomain", targets: ["CadenzaDomain"]),
        .library(name: "CadenzaKit", targets: ["CadenzaKit"]),
        .library(name: "CadenzaTesting", targets: ["CadenzaTesting"]),
        .library(name: "CadenzaLocalSources", targets: ["CadenzaLocalSources"]),
        .library(name: "CadenzaAVPlayback", targets: ["CadenzaAVPlayback"])
    ],
    targets: [
        .target(name: "CadenzaDomain"),
        .target(name: "CadenzaKit", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaTesting", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaLocalSources", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaAVPlayback", dependencies: ["CadenzaDomain"]),
        .testTarget(name: "CadenzaKitTests", dependencies: ["CadenzaKit", "CadenzaTesting", "CadenzaLocalSources", "CadenzaAVPlayback"])
    ]
)
