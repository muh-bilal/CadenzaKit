// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CadenzaDemo",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CadenzaDemo", targets: ["CadenzaDemo"])],
    dependencies: [.package(name: "CadenzaKit", path: "../..")],
    targets: [
        .target(name: "DemoCore", dependencies: [
            .product(name: "CadenzaKit", package: "CadenzaKit"),
            .product(name: "CadenzaDomain", package: "CadenzaKit"),
            .product(name: "CadenzaLocalSources", package: "CadenzaKit"),
            .product(name: "CadenzaAVPlayback", package: "CadenzaKit"),
            .product(name: "CadenzaPersistence", package: "CadenzaKit")
        ]),
        .executableTarget(name: "CadenzaDemo", dependencies: ["DemoCore"]),
        .testTarget(name: "DemoCoreTests", dependencies: ["DemoCore"])
    ]
)
