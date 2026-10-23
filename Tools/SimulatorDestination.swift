import Foundation

// Resolve installed runtimes at execution time; never commit a developer's device UUID.
struct SimulatorInventory: Decodable {
    struct Device: Decodable {
        let name: String
        let udid: String
        let isAvailable: Bool
    }
    let devices: [String: [Device]]

    func destination(for family: String) throws -> String {
        let platform: String, runtime: String, prefix: String
        switch family {
        case "iPhone": (platform, runtime, prefix) = ("iOS Simulator", ".iOS-", "iPhone")
        case "iPad": (platform, runtime, prefix) = ("iOS Simulator", ".iOS-", "iPad")
        case "tvOS": (platform, runtime, prefix) = ("tvOS Simulator", ".tvOS-", "Apple TV")
        default: throw Failure(message: "Unknown simulator family: \(family)")
        }
        for key in devices.keys.filter({ $0.contains(runtime) }).sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            if let device = devices[key]?.filter({ $0.isAvailable && $0.name.hasPrefix(prefix) }).sorted(by: { $0.name < $1.name }).first {
                return "platform=\(platform),id=\(device.udid)"
            }
        }
        throw Failure(message: "No available \(family) simulator. Install its runtime in Xcode before running validation.")
    }
}
struct Failure: Error { let message: String }

do {
    let family = CommandLine.arguments.dropFirst().first ?? "iPhone"
    if family == "--self-test" {
        let inventory = SimulatorInventory(devices: [
            "com.apple.CoreSimulator.SimRuntime.iOS-9-0": [.init(name: "iPhone Old", udid: "old", isAvailable: true)],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                .init(name: "iPhone Missing", udid: "missing", isAvailable: false),
                .init(name: "iPhone New", udid: "phone", isAvailable: true),
                .init(name: "iPad Pro", udid: "pad", isAvailable: true)],
            "com.apple.CoreSimulator.SimRuntime.tvOS-26-0": [.init(name: "Apple TV 4K", udid: "tv", isAvailable: true)]
        ])
        guard try inventory.destination(for: "iPhone") == "platform=iOS Simulator,id=phone",
              try inventory.destination(for: "iPad") == "platform=iOS Simulator,id=pad",
              try inventory.destination(for: "tvOS") == "platform=tvOS Simulator,id=tv" else { throw Failure(message: "Incorrect destination selection") }
        for family in ["iPhone", "unknown"] {
            do { _ = try SimulatorInventory(devices: [:]).destination(for: family); throw NSError(domain: "Expected failure", code: 1) }
            catch is Failure { }
        }
        print("Simulator selection tests passed")
    } else {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "available", "--json"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(message: "simctl failed") }
        print(try JSONDecoder().decode(SimulatorInventory.self, from: data).destination(for: family))
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
