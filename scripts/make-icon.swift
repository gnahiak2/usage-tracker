import AppKit

let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("could not create bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
let plate = NSBezierPath(roundedRect: canvas.insetBy(dx: 64, dy: 64), xRadius: 220, yRadius: 220)
NSGradient(colors: [NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.17, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)])?
    .draw(in: plate, angle: -90)

func bar(y: CGFloat, width: CGFloat, color: NSColor) {
    let rect = NSRect(x: 232, y: y, width: width, height: 64)
    let path = NSBezierPath(roundedRect: rect, xRadius: 32, yRadius: 32)
    color.setFill()
    path.fill()
}

bar(y: 624, width: 416, color: NSColor(calibratedRed: 0.86, green: 0.47, blue: 0.34, alpha: 1))
bar(y: 480, width: 560, color: NSColor(calibratedRed: 0.28, green: 0.56, blue: 0.98, alpha: 1))
bar(y: 336, width: 320, color: NSColor(calibratedRed: 0.20, green: 0.62, blue: 0.53, alpha: 1))

let dot = NSBezierPath(ovalIn: NSRect(x: 700, y: 336, width: 64, height: 64))
NSColor(calibratedWhite: 1, alpha: 0.82).setFill()
dot.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"))
