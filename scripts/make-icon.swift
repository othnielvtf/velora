import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let size = NSSize(width: pixels, height: pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = CGFloat(pixels) * 0.07
    let rect = NSRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: CGFloat(pixels) * 0.22, yRadius: CGFloat(pixels) * 0.22)
    NSGradient(starting: NSColor(red: 0.52, green: 0.4, blue: 0.91, alpha: 1), ending: NSColor(red: 0.12, green: 0.1, blue: 0.3, alpha: 1))!.draw(in: shape, angle: -75)
    NSColor(white: 1, alpha: 0.12).setStroke(); shape.lineWidth = max(1, CGFloat(pixels) * 0.008); shape.stroke()
    let p = CGFloat(pixels)
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: p * 0.40, y: p * 0.31))
    triangle.line(to: NSPoint(x: p * 0.40, y: p * 0.69))
    triangle.line(to: NSPoint(x: p * 0.72, y: p * 0.50)); triangle.close()
    NSColor(white: 1, alpha: 0.96).setFill(); triangle.fill()
    let arc = NSBezierPath()
    arc.move(to: NSPoint(x: p * 0.23, y: p * 0.34))
    arc.curve(to: NSPoint(x: p * 0.23, y: p * 0.66), controlPoint1: NSPoint(x: p * 0.15, y: p * 0.42), controlPoint2: NSPoint(x: p * 0.15, y: p * 0.58))
    NSColor(white: 1, alpha: 0.38).setStroke(); arc.lineWidth = p * 0.025; arc.lineCapStyle = .round; arc.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    if pixels <= 512 { try png.write(to: folder.appendingPathComponent("icon_\(pixels)x\(pixels).png")) }
    if pixels >= 32 { try png.write(to: folder.appendingPathComponent("icon_\(pixels/2)x\(pixels/2)@2x.png")) }
}
