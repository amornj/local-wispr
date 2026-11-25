import AppKit

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let n = CGFloat(pixels)
        let background = NSBezierPath(roundedRect: NSRect(x: n * 0.07, y: n * 0.07, width: n * 0.86, height: n * 0.86), xRadius: n * 0.2, yRadius: n * 0.2)
        NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.18, alpha: 1).setFill()
        background.fill()
        for (index, height) in [0.19, 0.37, 0.53, 0.31, 0.43].enumerated() {
            let h = n * height
            let bar = NSBezierPath(roundedRect: NSRect(x: n * (0.26 + CGFloat(index) * 0.102), y: (n - h) / 2, width: n * 0.056, height: h), xRadius: n * 0.028, yRadius: n * 0.028)
            if index == 2 { NSColor(calibratedRed: 0.9, green: 0.48, blue: 0.28, alpha: 1).setFill() }
            else { NSColor(calibratedRed: 0.965, green: 0.961, blue: 0.946, alpha: 1).setFill() }
            bar.fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
