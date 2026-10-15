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
        .library(name: "CadenzaAVPlayback", targets: ["CadenzaAVPlayback"]),
        .library(name: "CadenzaPersistence", targets: ["CadenzaPersistence"]),
        .library(name: "CadenzaArtwork", targets: ["CadenzaArtwork"]),
        .library(name: "CadenzaRemoteSources", targets: ["CadenzaRemoteSources"]),
        .library(name: "CadenzaDownloads", targets: ["CadenzaDownloads"]),
        .library(name: "CadenzaAudioEngine", targets: ["CadenzaAudioEngine"])
    ],
    targets: [
        .target(name: "CadenzaDomain"),
        .target(name: "CadenzaKit", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaTesting", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaLocalSources", dependencies: ["CadenzaDomain"], resources: [.copy("PrivacyInfo.xcprivacy")]),
        .target(name: "CadenzaAVPlayback", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaPersistence", dependencies: ["CadenzaDomain"], resources: [.copy("PrivacyInfo.xcprivacy")]),
        .target(name: "CadenzaArtwork", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaRemoteSources", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaDownloads", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaAudioEngine", dependencies: ["CadenzaDomain"]),
        .testTarget(name: "CadenzaKitTests", dependencies: ["CadenzaKit", "CadenzaTesting", "CadenzaLocalSources", "CadenzaAVPlayback", "CadenzaPersistence", "CadenzaArtwork", "CadenzaRemoteSources", "CadenzaDownloads", "CadenzaAudioEngine"])
    ]
)
