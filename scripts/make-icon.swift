// Draws the app icon (a white bell on an indigo squircle) into an .iconset folder for iconutil.
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let sizes: [(name: String, pixels: Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = CGFloat(pixels)
    // Apple's icon grid: an 824/1024 rounded square centered on the canvas.
    let inset = size * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(
        starting: NSColor(srgbRed: 0.40, green: 0.47, blue: 1.00, alpha: 1),
        ending: NSColor(srgbRed: 0.45, green: 0.25, blue: 0.85, alpha: 1)
    )!.draw(in: shape, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.40, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let bell = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let b = bell.size
        bell.draw(in: NSRect(x: (size - b.width) / 2, y: (size - b.height) / 2, width: b.width, height: b.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for (name, pixels) in sizes {
    try render(pixels).write(to: URL(fileURLWithPath: "\(output)/icon_\(name).png"))
}
