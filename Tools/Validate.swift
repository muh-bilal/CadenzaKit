import Foundation

// Run from the repository root: swift Tools/Validate.swift Local
// This orchestration utility is not shipped in an SDK product.
struct ValidationFailure: Error { let message: String }
do {
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let runName = CommandLine.arguments.dropFirst().first ?? "Manual"
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
    environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
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
let coveragePath = root.appendingPathComponent(".build/arm64-apple-macosx/debug/codecov/CadenzaKit.json")
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

// Separate platforms: this Xcode crashes when a package test command mixes SDKs.
let destinations = [
    ("macOS", "platform=macOS"),
    ("iPhone", "platform=iOS Simulator,id=113657B5-DCC6-4619-A0EA-F1AF8650B69C"),
    ("iPad", "platform=iOS Simulator,id=9550BD2F-73CE-40DB-A39D-F74B6DE775D5"),
    ("tvOS", "platform=tvOS Simulator,id=B4F98CFA-6645-425D-BA4F-148261250A42")
]
for (name, destination) in destinations {
    try run([
        "xcodebuild", "test", "-scheme", "CadenzaKit-Package",
        "-destination", destination, "-parallel-testing-enabled", "NO",
        "-enableCodeCoverage", "YES", "-derivedDataPath", "/tmp/CadenzaKitDerivedData",
        "-resultBundlePath", artifacts.appendingPathComponent("\(name).xcresult").path
    ], log: "\(name).log")
}
try run(["git", "diff", "--check"], log: "diff-check.log")
print("Validation passed; review the diff and evidence before committing.")
} catch {
    print("Validation failed: \(error)")
    exit(1)
}
