import Foundation
// Regenerate from this directory; the checked-in project requires no generator.
var objects: [String: [String: Any]] = [:], serial = 0
func add(_ value: [String: Any]) -> String {
    serial += 1; let id = String(format: "%024X", serial); objects[id] = value; return id
}
func file(_ path: String, _ type: String) -> String {
    add(["isa": "PBXFileReference", "path": path, "sourceTree": "<group>", "lastKnownFileType": type])
}
func phase(_ kind: String, _ refs: [String]) -> String {
    add(["isa": kind, "buildActionMask": 2147483647, "files": refs.map { add(["isa": "PBXBuildFile", "fileRef": $0]) }, "runOnlyForDeploymentPostprocessing": 0])
}
func configs(_ settings: [String: Any]) -> String {
    let values = ["Debug", "Release"].map { name in
        var s = settings; s["SWIFT_OPTIMIZATION_LEVEL"] = name == "Debug" ? "-Onone" : "-O"
        s["ONLY_ACTIVE_ARCH"] = name == "Debug" ? "YES" : "NO"
        s["DEBUG_INFORMATION_FORMAT"] = "dwarf-with-dsym"
        return add(["isa": "XCBuildConfiguration", "name": name, "buildSettings": s])
    }
    return add(["isa": "XCConfigurationList", "buildConfigurations": values, "defaultConfigurationIsVisible": 0, "defaultConfigurationName": "Release"])
}
let source = file("App/CadenzaDemo.swift", "sourcecode.swift")
let artwork = file("App/DemoArtwork.swift", "sourcecode.swift")
let screen = file("App/DemoPlayerScreen.swift", "sourcecode.swift")
let assets = file("App/DemoAssets.xcassets", "folder.assetcatalog")
let translations = ["en", "de"].map { language in add(["isa": "PBXFileReference", "name": language, "path": "App/Resources/\(language).lproj/Showcase.strings", "sourceTree": "<group>", "lastKnownFileType": "text.plist.strings"]) }
let localized = add(["isa": "PBXVariantGroup", "name": "Showcase.strings", "sourceTree": "<group>", "children": translations])
let model = file("App/DemoModel.swift", "sourcecode.swift")
let carPlay = file("App/CarPlayScene.swift", "sourcecode.swift")
let unitSource = file("Tests/ShowcaseModelTests.swift", "sourcecode.swift")
let modelTests = file("Tests/DemoModelTests.swift", "sourcecode.swift")
var unitTarget: String?
let tests = file("UITests/ShowcaseTests.swift", "sourcecode.swift")
let strings = file("App/Localizable.xcstrings", "text.json.xcstrings")
let package = add(["isa": "XCLocalSwiftPackageReference", "relativePath": "../.."])
let products = add(["isa": "PBXGroup", "name": "Products", "sourceTree": "<group>", "children": [String]()])
let group = add(["isa": "PBXGroup", "sourceTree": "<group>", "children": [source, artwork, screen, model, carPlay, strings, localized, assets, tests, unitSource, modelTests, products]])
var targets: [String] = [], output: [String] = [], schemes: [(String, String, String)] = []
for (platform, sdk, supported, family, deployment, version) in [
    ("iOS", "iphoneos", "iphoneos iphonesimulator", "1,2", "IPHONEOS_DEPLOYMENT_TARGET", "17.0"),
    ("macOS", "macosx", "macosx", "", "MACOSX_DEPLOYMENT_TARGET", "14.0"),
    ("tvOS", "appletvos", "appletvos appletvsimulator", "3", "TVOS_DEPLOYMENT_TARGET", "17.0")
] {
    let name = "Cadenza\(platform)"
    var settings: [String: Any] = ["SWIFT_EMIT_LOC_STRINGS": "NO", "SWIFT_VERSION": "6.0", "SDKROOT": sdk, "SUPPORTED_PLATFORMS": supported,
        deployment: version, "PRODUCT_NAME": "$(TARGET_NAME)", "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_CFBundleDisplayName": "CadenzaDemo", "MARKETING_VERSION": "1.0", "CURRENT_PROJECT_VERSION": "1",
        "PRODUCT_BUNDLE_IDENTIFIER": "org.cadenzakit.showcase.\(platform.lowercased())", "CODE_SIGN_STYLE": "Automatic",
        "ENABLE_TESTABILITY": "YES", "SWIFT_STRICT_CONCURRENCY": "complete", "SUPPORTS_MACCATALYST": "NO",
        "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.music"]
    if !family.isEmpty { settings["TARGETED_DEVICE_FAMILY"] = family }
    if platform == "iOS" {
        settings["INFOPLIST_KEY_UILaunchScreen_Generation"] = "YES"
        settings["INFOPLIST_KEY_UISupportedInterfaceOrientations"] = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
    }
    if platform == "macOS" { settings["ENABLE_APP_SANDBOX"] = "YES" }
    if platform != "macOS" { settings["INFOPLIST_FILE"] = "App/BackgroundAudio.plist" }
    if platform == "iOS" {
        settings["INFOPLIST_FILE"] = "App/iOS.plist"
        settings["CODE_SIGN_ENTITLEMENTS"] = "App/CarPlay.entitlements"
    }
    let product = add(["isa": "PBXFileReference", "path": "\(name).app", "explicitFileType": "wrapper.application", "sourceTree": "BUILT_PRODUCTS_DIR"])
    output.append(product)
    let dependencies = ["CadenzaCarPlay", "CadenzaPlayer", "CadenzaSystemPlayback", "CadenzaKit", "CadenzaDomain", "CadenzaLocalSources", "CadenzaAudioEngine", "CadenzaSwiftUI", "CadenzaPersistence"].map {
        add(["isa": "XCSwiftPackageProductDependency", "package": package, "productName": $0])
    }
    let frameworks = add(["isa": "PBXFrameworksBuildPhase", "buildActionMask": 2147483647, "files": dependencies.map { add(["isa": "PBXBuildFile", "productRef": $0]) }, "runOnlyForDeploymentPostprocessing": 0])
    let app = add(["isa": "PBXNativeTarget", "name": name, "productName": name, "productReference": product, "productType": "com.apple.product-type.application", "buildConfigurationList": configs(settings), "buildPhases": [phase("PBXSourcesBuildPhase", [source, artwork, screen, model, carPlay]), frameworks, phase("PBXResourcesBuildPhase", [strings, localized, assets])], "buildRules": [String](), "dependencies": [String](), "packageProductDependencies": dependencies])
    targets.append(app)
    if platform == "macOS" {
        var unitSettings = settings
        unitSettings["PRODUCT_BUNDLE_IDENTIFIER"] = "org.cadenzakit.showcase.modeltests"
        unitSettings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/CadenzamacOS.app/Contents/MacOS/CadenzamacOS"
        unitSettings["BUNDLE_LOADER"] = "$(TEST_HOST)"
        let unitProduct = add(["isa": "PBXFileReference", "path": "ShowcaseModelTests.xctest", "explicitFileType": "wrapper.cfbundle", "sourceTree": "BUILT_PRODUCTS_DIR"])
        output.append(unitProduct)
        let unitFrameworks = add(["isa": "PBXFrameworksBuildPhase", "buildActionMask": 2147483647, "files": dependencies.map { add(["isa": "PBXBuildFile", "productRef": $0]) }, "runOnlyForDeploymentPostprocessing": 0])
        let unit = add(["isa": "PBXNativeTarget", "name": "ShowcaseModelTests", "productName": "ShowcaseModelTests", "productReference": unitProduct, "productType": "com.apple.product-type.bundle.unit-test", "buildConfigurationList": configs(unitSettings), "buildPhases": [phase("PBXSourcesBuildPhase", [unitSource, modelTests]), unitFrameworks], "buildRules": [String](), "dependencies": [add(["isa": "PBXTargetDependency", "target": app])], "packageProductDependencies": dependencies])
        targets.append(unit); unitTarget = unit
    }
    settings["PRODUCT_BUNDLE_IDENTIFIER"] = "org.cadenzakit.showcase.\(platform.lowercased()).uitests"
    settings.removeValue(forKey: "INFOPLIST_FILE")
    settings.removeValue(forKey: "CODE_SIGN_ENTITLEMENTS")
    settings["TEST_TARGET_NAME"] = name; settings["ENABLE_APP_SANDBOX"] = "NO"
    let testProduct = add(["isa": "PBXFileReference", "path": "\(name)UITests.xctest", "explicitFileType": "wrapper.cfbundle", "sourceTree": "BUILT_PRODUCTS_DIR"])
    output.append(testProduct)
    let test = add(["isa": "PBXNativeTarget", "name": "\(name)UITests", "productName": "\(name)UITests", "productReference": testProduct, "productType": "com.apple.product-type.bundle.ui-testing", "buildConfigurationList": configs(settings), "buildPhases": [phase("PBXSourcesBuildPhase", [tests]), phase("PBXFrameworksBuildPhase", []), phase("PBXResourcesBuildPhase", [strings])], "buildRules": [String](), "dependencies": [add(["isa": "PBXTargetDependency", "target": app])]])
    targets.append(test); schemes.append((name, app, test))
}
objects[products]?["children"] = output
let project = add(["isa": "PBXProject", "attributes": ["BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2600"], "buildConfigurationList": configs(["CLANG_ENABLE_MODULES": "YES"]), "compatibilityVersion": "Xcode 14.0", "developmentRegion": "en", "knownRegions": ["en", "de", "Base"], "mainGroup": group, "productRefGroup": products, "projectDirPath": "", "projectRoot": "", "targets": targets, "packageReferences": [package]])
func encode(_ value: Any) -> String {
    if let d = value as? [String: Any] { return "{\n" + d.keys.sorted().map { "\(encode($0)) = \(encode(d[$0]!));" }.joined(separator: "\n") + "\n}" }
    if let a = value as? [Any] { return "(" + a.map(encode).joined(separator: ", ") + ")" }
    if let s = value as? String { return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    return "\(value)"
}
let path = "CadenzaDemo.xcodeproj"
try FileManager.default.createDirectory(atPath: "\(path)/xcshareddata/xcschemes", withIntermediateDirectories: true)
try ("// !$*UTF8*$!\n" + encode(["archiveVersion": 1, "classes": [String: String](), "objectVersion": 56, "objects": objects, "rootObject": project])).write(toFile: "\(path)/project.pbxproj", atomically: true, encoding: .utf8)
for (name, app, test) in schemes {
    func ref(_ id: String, _ target: String, _ product: String) -> String {
        "<BuildableReference BuildableIdentifier=\"primary\" BlueprintIdentifier=\"\(id)\" BuildableName=\"\(product)\" BlueprintName=\"\(target)\" ReferencedContainer=\"container:CadenzaDemo.xcodeproj\"/>"
    }
    let appRef = ref(app, name, "\(name).app"), testRef = ref(test, "\(name)UITests", "\(name)UITests.xctest")
    let unitRef = name == "CadenzamacOS" ? "<TestableReference skipped=\"NO\">\(ref(unitTarget!, "ShowcaseModelTests", "ShowcaseModelTests.xctest"))</TestableReference>" : ""
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Scheme LastUpgradeVersion="2600" version="1.3">
    <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">\(appRef)</BuildActionEntry></BuildActionEntries></BuildAction>
    <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES" codeCoverageEnabled="YES"><Testables><TestableReference skipped="NO">\(testRef)</TestableReference>\(unitRef)</Testables></TestAction>
    <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">\(appRef)</BuildableProductRunnable></LaunchAction>
    <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">\(appRef)</BuildableProductRunnable></ProfileAction>
    <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
    </Scheme>
    """
    try xml.write(toFile: "\(path)/xcshareddata/xcschemes/\(name).xcscheme", atomically: true, encoding: .utf8)
}
