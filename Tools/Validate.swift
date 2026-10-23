import Foundation

// Run from the repository root: swift Tools/Validate.swift Local [macOS|iPhone|iPad|tvOS]
// Without a platform, run all SDK gates. UI tests have a separate workflow.
// This orchestration utility is not shipped in an SDK product.
struct ValidationFailure: Error { let message: String }
do {
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let runName = CommandLine.arguments.dropFirst().first ?? "Manual"
let selectedPlatform = CommandLine.arguments.dropFirst(2).first
let platforms = ["macOS", "iPhone", "iPad", "tvOS"]
guard selectedPlatform == nil || platforms.contains(selectedPlatform!) else { throw ValidationFailure(message: "Unknown platform") }
let artifacts = root.appendingPathComponent(".build/validation/\(runName)")
try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)

@discardableResult
func run(_ arguments: [String], log name: String) throws -> String {
    let logURL = artifacts.appendingPathComponent(name)
    guard !FileManager.default.fileExists(atPath: logURL.path) else {
        throw ValidationFailure(message: "Refusing to overwrite evidence: \(logURL.path)")
    }
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: logURL)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    if environment["DEVELOPER_DIR"] == nil { environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer" }
    process.environment = environment
    process.standardOutput = handle
    process.standardError = handle
    print("Running \(arguments.joined(separator: " "))")
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ValidationFailure(message: "Exit \(process.terminationStatus); see \(logURL.path)")
    }
    return try String(contentsOf: logURL, encoding: .utf8)
}

if selectedPlatform == nil || selectedPlatform == "macOS" {
try run(["swift", "build"], log: "build.log")
try run(["swift", "test", "--enable-code-coverage"], log: "swift.log")

struct Coverage: Decodable {
    struct Datum: Decodable {
        struct File: Decodable {
            struct Summary: Decodable {
                struct Lines: Decodable { let count: Int; let covered: Int }
                let lines: Lines
            }
            let filename: String
            let summary: Summary
        }
        let files: [File]
    }
    let data: [Datum]
}
let coveragePath = URL(fileURLWithPath: try run(["swift", "test", "--show-codecov-path"], log: "coverage-path.log").trimmingCharacters(in: .whitespacesAndNewlines))
let coverage = try JSONDecoder().decode(Coverage.self, from: Data(contentsOf: coveragePath))
let sourceRoot = root.appendingPathComponent("Sources").path + "/"
let files = coverage.data.flatMap(\.files).filter { $0.filename.hasPrefix(sourceRoot) }
let enumerator = FileManager.default.enumerator(atPath: sourceRoot)!
let expected = Set(enumerator.allObjects.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") })
let actual = Set(files.map { String($0.filename.dropFirst(sourceRoot.count)) })
guard expected == actual, !files.isEmpty else {
    throw ValidationFailure(message: "Coverage inventory mismatch. Missing: \(expected.subtracting(actual))")
}
var report = "Actual validation: \(Date().ISO8601Format())\n"
for file in files.sorted(by: { $0.filename < $1.filename }) {
    let lines = file.summary.lines
    report += "\(file.filename.dropFirst(sourceRoot.count)): \(lines.covered)/\(lines.count) executable lines\n"
}
try report.write(to: artifacts.appendingPathComponent("coverage.txt"), atomically: true, encoding: .utf8)
print(report)
guard files.allSatisfy({ $0.summary.lines.covered == $0.summary.lines.count }) else {
    throw ValidationFailure(message: "Owned production line coverage is below 100%")
}

}

// Separate platforms: Xcode package tests must not mix SDKs in one invocation.
for name in platforms where selectedPlatform == nil || selectedPlatform == name {
    let destination = name == "macOS" ? "platform=macOS" : try run(
        ["swift", "Tools/SimulatorDestination.swift", name], log: "\(name)-destination.log").trimmingCharacters(in: .whitespacesAndNewlines)
    try run([
        "xcodebuild", "test", "-scheme", "CadenzaKit-Package",
        "-destination", destination, "-parallel-testing-enabled", "NO",
        "-enableCodeCoverage", "YES", "-derivedDataPath", artifacts.appendingPathComponent("DerivedData-\(name)").path,
        "-resultBundlePath", artifacts.appendingPathComponent("\(name).xcresult").path
    ], log: "\(name).log")
    // This optional adapter contains iOS-only CarPlay template code. Its native
    // lines must pass coverage on iPhone/iPad, not just the portable Mac build.
    struct PlatformCoverage: Decodable {
        struct Target: Decodable { let name: String; let lineCoverage: Double }
        let targets: [Target]
    }
    let platformCoverage = try run(["xcrun", "xccov", "view", "--report", "--json",
        artifacts.appendingPathComponent("\(name).xcresult").path], log: "\(name)-coverage.json")
    let targets = try JSONDecoder().decode(PlatformCoverage.self, from: Data(platformCoverage.utf8)).targets
    guard let carPlay = targets.first(where: { $0.name == "CadenzaCarPlay" }), carPlay.lineCoverage == 1 else {
        throw ValidationFailure(message: "CarPlay adapter coverage is below 100% on \(name)")
    }
}
try run(["git", "diff", "--check"], log: "diff-check.log")
print("Validation passed; review the diff and evidence before committing.")
} catch {
    print("Validation failed: \(error)")
    exit(1)
}
