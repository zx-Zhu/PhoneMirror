import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let iconsetURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("PhoneMirror-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconsetURL) }

func render(size: Int, filename: String) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let side = CGFloat(size)
    let canvas = NSRect(x: 0, y: 0, width: side, height: side)
    let background = NSBezierPath(roundedRect: canvas.insetBy(dx: side * 0.055, dy: side * 0.055),
                                  xRadius: side * 0.22, yRadius: side * 0.22)
    background.addClip()
    NSGradient(colors: [
        NSColor(red: 0.14, green: 0.30, blue: 0.98, alpha: 1),
        NSColor(red: 0.00, green: 0.78, blue: 0.84, alpha: 1)
    ])?.draw(in: background, angle: -45)

    NSColor.white.withAlphaComponent(0.98).setStroke()
    let phoneRect = NSRect(x: side * 0.30, y: side * 0.17, width: side * 0.40, height: side * 0.66)
    let phone = NSBezierPath(roundedRect: phoneRect, xRadius: side * 0.075, yRadius: side * 0.075)
    phone.lineWidth = side * 0.045
    phone.stroke()

    let screen = NSBezierPath(roundedRect: phoneRect.insetBy(dx: side * 0.052, dy: side * 0.09),
                              xRadius: side * 0.028, yRadius: side * 0.028)
    NSColor.white.withAlphaComponent(0.20).setFill()
    screen.fill()

    let dot = NSBezierPath(ovalIn: NSRect(x: side * 0.48, y: side * 0.205, width: side * 0.04, height: side * 0.04))
    NSColor.white.setFill()
    dot.fill()

    NSColor.white.withAlphaComponent(0.96).setStroke()
    for index in 0..<2 {
        let inset = CGFloat(index) * side * 0.075
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: side * 0.72, y: side * 0.50),
                      radius: side * 0.17 + inset, startAngle: -52, endAngle: 52)
        arc.lineWidth = side * 0.032
        arc.lineCapStyle = .round
        arc.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    try data.write(to: iconsetURL.appendingPathComponent(filename), options: .atomic)
}

for base in [16, 32, 128, 256, 512] {
    try render(size: base, filename: "icon_\(base)x\(base).png")
    try render(size: base * 2, filename: "icon_\(base)x\(base)@2x.png")
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", output]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
