// Generates Resources/AppIcon.icns — a slate rounded square with a broom glyph.
// Run: swift scripts/make-icon.swift
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let fm = FileManager.default
let iconsetURL = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? fm.removeItem(at: iconsetURL)
try! fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func render(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels)
    let inset = s * 0.05
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.21, yRadius: s * 0.21)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.28, alpha: 1),
                              ending: NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.15, alpha: 1))!
    gradient.draw(in: path, angle: -90)

    let glyph = "🧹" as NSString
    let fontSize = s * 0.55
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize)]
    let glyphSize = glyph.size(withAttributes: attrs)
    glyph.draw(at: NSPoint(x: (s - glyphSize.width) / 2, y: (s - glyphSize.height) / 2), withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for size in sizes {
    let rep = render(size)
    let png = rep.representation(using: .png, properties: [:])!
    if size <= 512 {
        try! png.write(to: iconsetURL.appendingPathComponent("icon_\(size)x\(size).png"))
    }
    if size >= 32 {
        try! png.write(to: iconsetURL.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png"))
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetURL.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconsetURL)
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
