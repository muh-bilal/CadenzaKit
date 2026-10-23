import Foundation

// Run from Examples/CadenzaDemo. No project generator or third-party tools required.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", "build", "--enable-code-coverage"]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
let bin = root.appendingPathComponent(".build/debug").resolvingSymlinksInPath()
let app = root.appendingPathComponent(".build/CadenzaDemo.app")
let contents = app.appendingPathComponent("Contents")
let executable = contents.appendingPathComponent("MacOS/CadenzaDemo")
try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
if FileManager.default.fileExists(atPath: executable.path) { try FileManager.default.removeItem(at: executable) }
try FileManager.default.copyItem(at: bin.appendingPathComponent("CadenzaDemo"), to: executable)
for resource in try FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil) where resource.pathExtension == "bundle" {
    let destination = app.appendingPathComponent(resource.lastPathComponent)
    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
    try FileManager.default.copyItem(at: resource, to: destination)
}
let info: [String: Any] = ["CFBundleIdentifier": "org.cadenzakit.demo", "CFBundleName": "CadenzaDemo", "CFBundleExecutable": "CadenzaDemo", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "NSHighResolutionCapable": true, "LSMinimumSystemVersion": "14.0"]
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
print("Built \(app.path)")
