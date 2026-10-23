import AppKit
// Original example-only template assets, dedicated to CC0-1.0.
let root = URL(fileURLWithPath: "App/DemoAssets.xcassets")
let fm = FileManager.default
try fm.createDirectory(at: root, withIntermediateDirectories: true)
try Data(#"{"info":{"author":"CadenzaKit","version":1}}"#.utf8).write(to: root.appendingPathComponent("Contents.json"))
for name in ["DemoPlay", "DemoPause"] {
    let folder = root.appendingPathComponent("\(name).imageset")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setStrokeColor(NSColor.black.cgColor); context.setFillColor(NSColor.black.cgColor)
    context.setLineWidth(7); context.strokeEllipse(in: CGRect(x: 8, y: 8, width: 112, height: 112))
    if name == "DemoPlay" {
        context.move(to: CGPoint(x: 49, y: 36)); context.addLine(to: CGPoint(x: 49, y: 92)); context.addLine(to: CGPoint(x: 91, y: 64)); context.closePath(); context.fillPath()
    } else {
        context.fill(CGRect(x: 42, y: 36, width: 15, height: 56)); context.fill(CGRect(x: 71, y: 36, width: 15, height: 56))
    }
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon.png"))
    try Data(#"{"images":[{"filename":"icon.png","idiom":"universal"}],"info":{"author":"CadenzaKit","version":1},"properties":{"template-rendering-intent":"template"}}"#.utf8).write(to: folder.appendingPathComponent("Contents.json"))
}
