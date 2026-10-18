// Draws Burrow's app icon: a rounded tile with stacked "layers" sinking into a burrow.
// Usage: swift scripts/make-icon.swift Support/AppIcon.icns
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.12, blue: 0.32, alpha: 1),
                        NSColor(red: 0.42, green: 0.24, blue: 0.62, alpha: 1)])!.draw(in: shape, angle: 90)
    shape.addClip()
    // Three stacked layers, each a lighter, wider ellipse: machines nested in the host.
    let colors = [NSColor(red: 1.0, green: 0.62, blue: 0.25, alpha: 1),
                  NSColor(red: 1.0, green: 0.78, blue: 0.40, alpha: 1),
                  NSColor(red: 1.0, green: 0.92, blue: 0.70, alpha: 1)]
    for (index, color) in colors.enumerated() {
        let width = tile.width * (0.42 + 0.14 * CGFloat(index))
        let height = width * 0.34
        let y = tile.minY + tile.height * (0.58 - 0.15 * CGFloat(index))
        let ellipse = NSBezierPath(ovalIn: NSRect(x: tile.midX - width / 2, y: y, width: width, height: height))
        color.setFill()
        ellipse.fill()
    }
    // The burrow entrance.
    let hole = NSBezierPath(ovalIn: NSRect(x: tile.midX - tile.width * 0.13, y: tile.minY + tile.height * 0.68,
                                           width: tile.width * 0.26, height: tile.width * 0.16))
    NSColor(red: 0.10, green: 0.07, blue: 0.20, alpha: 1).setFill()
    hole.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Burrow-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
