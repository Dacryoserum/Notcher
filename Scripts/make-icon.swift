import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func draw(size: Int, name: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let outer = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 211, yRadius: 211)
    NSGradient(starting: NSColor(white: 0.13, alpha: 1), ending: NSColor(white: 0.035, alpha: 1))!.draw(in: outer, angle: -90)
    NSColor(white: 1, alpha: 0.10).setStroke(); outer.lineWidth = 3; outer.stroke()
    let screen = NSBezierPath(roundedRect: NSRect(x: 190, y: 233, width: 644, height: 538), xRadius: 81, yRadius: 81)
    NSColor(calibratedRed: 0.70, green: 0.93, blue: 0.66, alpha: 1).setFill(); screen.fill()
    let notch = NSBezierPath()
    notch.move(to: NSPoint(x: 333, y: 777)); notch.line(to: NSPoint(x: 691, y: 777)); notch.line(to: NSPoint(x: 691, y: 668))
    notch.curve(to: NSPoint(x: 638, y: 615), controlPoint1: NSPoint(x: 691, y: 628), controlPoint2: NSPoint(x: 674, y: 615))
    notch.line(to: NSPoint(x: 386, y: 615)); notch.curve(to: NSPoint(x: 333, y: 668), controlPoint1: NSPoint(x: 350, y: 615), controlPoint2: NSPoint(x: 333, y: 628)); notch.close()
    NSColor(white: 0.10, alpha: 1).setFill(); notch.fill()
    for (i, height) in [42, 89, 132, 72, 108, 48].enumerated() {
        let bar = NSBezierPath(roundedRect: NSRect(x: 355 + i * 54, y: 382 - height / 2, width: 25, height: height), xRadius: 12, yRadius: 12)
        NSColor(calibratedRed: 0.13, green: 0.24, blue: 0.16, alpha: 0.85).setFill(); bar.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
for size in [16, 32, 128, 256, 512] {
    try draw(size: size, name: "icon_\(size)x\(size).png")
    try draw(size: size * 2, name: "icon_\(size)x\(size)@2x.png")
}

// ICNS is a container of PNG representations; pack directly without ImageIO's XPC converter.
func lengthData(_ value: Int) -> Data { var big = UInt32(value).bigEndian; return Data(bytes: &big, count: 4) }
var chunks = Data()
for (type, file) in [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"), ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"), ("ic14", "icon_256x256@2x.png")] {
    let png = try Data(contentsOf: output.appendingPathComponent(file))
    chunks.append(Data(type.utf8)); chunks.append(lengthData(png.count + 8)); chunks.append(png)
}
var icns = Data("icns".utf8); icns.append(lengthData(chunks.count + 8)); icns.append(chunks)
try icns.write(to: output.deletingLastPathComponent().appendingPathComponent("Notcher.icns"))
