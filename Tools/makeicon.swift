import AppKit

// Draws the app icon at 1024×1024.  The plate uses the macOS icon grid:
// an 824pt rounded square centred in a 1024pt canvas, leaving room for the
// drop shadow.  Run through icon.sh to produce AppIcon.icns.

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let side = 1024

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: side,
    pixelsHigh: side,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("could not create bitmap")
}
bitmap.size = NSSize(width: side, height: side)

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("could not create graphics context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
context.cgContext.setAllowsAntialiasing(true)
context.cgContext.setShouldAntialias(true)
context.imageInterpolation = .high

func rgb(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((value >> 16) & 0xff) / 255,
        green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255,
        alpha: alpha
    )
}

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

// MARK: - Plate

let plateRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let plate = rounded(plateRect, 186)

let plateShadow = NSShadow()
plateShadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
plateShadow.shadowBlurRadius = 30
plateShadow.shadowOffset = NSSize(width: 0, height: -14)
NSGraphicsContext.saveGraphicsState()
plateShadow.set()
NSColor.black.setFill()
plate.fill()
NSGraphicsContext.restoreGraphicsState()

let plateGradient = NSGradient(colors: [
    rgb(0x4FA8FF),
    rgb(0x1D6BE8),
    rgb(0x0B4FC7),
])!
plateGradient.draw(in: plate, angle: -90)

// A soft sheen keeps the flat gradient from looking dull.
NSGraphicsContext.saveGraphicsState()
plate.addClip()
let sheen = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.14),
    NSColor.white.withAlphaComponent(0),
])!
sheen.draw(
    in: NSRect(x: 100, y: 100, width: 824, height: 824),
    angle: -90
)
NSGraphicsContext.restoreGraphicsState()

let plateEdge = rounded(plateRect.insetBy(dx: 1.5, dy: 1.5), 184.5)
rgb(0xFFFFFF, alpha: 0.20).setStroke()
plateEdge.lineWidth = 3
plateEdge.stroke()

// MARK: - Envelope

let bodyRect = NSRect(x: 250, y: 318, width: 524, height: 368)
let body = rounded(bodyRect, 44)

let bodyShadow = NSShadow()
bodyShadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
bodyShadow.shadowBlurRadius = 26
bodyShadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState()
bodyShadow.set()
NSColor.white.setFill()
body.fill()
NSGraphicsContext.restoreGraphicsState()

let bodyGradient = NSGradient(colors: [
    rgb(0xFFFFFF),
    rgb(0xF2F7FF),
])!
bodyGradient.draw(in: body, angle: -90)

NSGraphicsContext.saveGraphicsState()
body.addClip()

// Folded top flap.
let flap = NSBezierPath()
flap.move(to: NSPoint(x: 250, y: 686))
flap.line(to: NSPoint(x: 512, y: 466))
flap.line(to: NSPoint(x: 774, y: 686))
flap.close()

let flapGradient = NSGradient(colors: [
    rgb(0xE7F1FF),
    rgb(0xBFD9FF),
])!
flapGradient.draw(in: flap, angle: -90)

rgb(0x9FC6FF).setStroke()
flap.lineWidth = 9
flap.stroke()

// Lower folds, kept faint so the envelope still reads at 16 pt.
let crease = NSBezierPath()
crease.move(to: NSPoint(x: 268, y: 326))
crease.line(to: NSPoint(x: 512, y: 466))
crease.move(to: NSPoint(x: 756, y: 326))
crease.line(to: NSPoint(x: 512, y: 466))
rgb(0xCFE3FF).setStroke()
crease.lineWidth = 9
crease.lineCapStyle = .round
crease.stroke()

NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: outputPath))
