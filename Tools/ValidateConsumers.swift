import Foundation

// Verify that a host can select each product independently. No source generation
// is checked into SDK targets; fixtures remain under ignored validation artifacts.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
for product in ["CadenzaDomain", "CadenzaKit", "CadenzaTesting", "CadenzaLocalSources", "CadenzaAVPlayback", "CadenzaPersistence", "CadenzaArtwork", "CadenzaRemoteSources", "CadenzaDownloads", "CadenzaAudioEngine", "CadenzaSwiftUI", "CadenzaPresentation"] {
    let directory = root.appendingPathComponent(".build/validation/Consumers/Consumer-\(product)")
    let sources = directory.appendingPathComponent("Sources/Consumer")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let manifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(name: "Consumer", platforms: [.macOS(.v14)],
        dependencies: [.package(path: "../../../..")],
        targets: [.executableTarget(name: "Consumer", dependencies: [
            .product(name: "\(product)", package: "CadenzaKit")
        ])])
    """
    try manifest.write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try "import \(product)\nprint(\"\(product) imported\")\n".write(
        to: sources.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", "run", "--package-path", directory.path, "Consumer"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        print("Consumer failed: \(product)")
        exit(1)
    }
}
