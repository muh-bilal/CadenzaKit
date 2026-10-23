// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CadenzaKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17)],
    products: [
        .library(name: "CadenzaPlayer", targets: ["CadenzaPlayer"]),
        .library(name: "CadenzaDomain", targets: ["CadenzaDomain"]),
        .library(name: "CadenzaKit", targets: ["CadenzaKit"]),
        .library(name: "CadenzaTesting", targets: ["CadenzaTesting"]),
        .library(name: "CadenzaLocalSources", targets: ["CadenzaLocalSources"]),
        .library(name: "CadenzaSystemPlayback", targets: ["CadenzaSystemPlayback"]),
        .library(name: "CadenzaAVPlayback", targets: ["CadenzaAVPlayback"]),
        .library(name: "CadenzaPersistence", targets: ["CadenzaPersistence"]),
        .library(name: "CadenzaArtwork", targets: ["CadenzaArtwork"]),
        .library(name: "CadenzaRemoteSources", targets: ["CadenzaRemoteSources"]),
        .library(name: "CadenzaDownloads", targets: ["CadenzaDownloads"]),
        .library(name: "CadenzaAudioEngine", targets: ["CadenzaAudioEngine"]),
        .library(name: "CadenzaSwiftUI", targets: ["CadenzaSwiftUI"]),
        .library(name: "CadenzaPresentation", targets: ["CadenzaPresentation"])
    ],
    targets: [
        .target(name: "CadenzaPlayer", dependencies: ["CadenzaKit", "CadenzaDomain", "CadenzaAVPlayback", "CadenzaSystemPlayback"]),
        .target(name: "CadenzaDomain"),
        .target(name: "CadenzaKit", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaTesting", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaLocalSources", dependencies: ["CadenzaDomain"], resources: [.copy("PrivacyInfo.xcprivacy")]),
        .target(name: "CadenzaSystemPlayback", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaAVPlayback", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaPersistence", dependencies: ["CadenzaDomain"], resources: [.copy("PrivacyInfo.xcprivacy")]),
        .target(name: "CadenzaArtwork", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaRemoteSources", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaDownloads", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaAudioEngine", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaPresentation", dependencies: ["CadenzaDomain"]),
        .target(name: "CadenzaSwiftUI", dependencies: ["CadenzaDomain", "CadenzaPresentation"], resources: [.process("Resources")]),
        .testTarget(name: "CadenzaSwiftUITests", dependencies: ["CadenzaSwiftUI", "CadenzaDomain"]),
        .testTarget(name: "CadenzaKitTests", dependencies: ["CadenzaPlayer", "CadenzaSystemPlayback", "CadenzaKit", "CadenzaTesting", "CadenzaLocalSources", "CadenzaAVPlayback", "CadenzaPersistence", "CadenzaArtwork", "CadenzaRemoteSources", "CadenzaDownloads", "CadenzaAudioEngine"])
    ]
)
