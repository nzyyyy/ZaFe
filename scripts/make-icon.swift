import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Usage: make-icon.swift <iconset-directory>") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

        let shape = NSBezierPath(roundedRect: NSRect(x: 74, y: 74, width: 876, height: 876), xRadius: 200, yRadius: 200)
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        shape.fill()
        let sheen = NSGradient(starting: NSColor(calibratedWhite: 0.26, alpha: 1), ending: NSColor(calibratedWhite: 0.11, alpha: 1))!
        sheen.draw(in: shape, angle: -90)

        for (index, y) in [CGFloat(310), 454, 598].enumerated() {
            let rect = NSRect(x: 260 + CGFloat(index) * 18, y: y, width: 466 - CGFloat(index) * 18, height: 100)
            NSColor(calibratedWhite: 1, alpha: 0.28 + Double(index) * 0.28).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
        try data.write(to: url)
    }
}
