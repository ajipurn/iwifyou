import AppKit

// iwifyou mark: a lowercase "i" whose dot broadcasts two signal waves.
// Flat colours only. Keep geometry and colours in sync with
// Sources/iwifyou/Logo.swift, which draws the in-app and menu bar mark.

struct Palette {
    let tile: CGColor
    let letter: CGColor
    let waves: CGColor
    let border: CGColor?
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let palettes = [
    Palette(tile: rgb(0x17181C), letter: rgb(0xFFFFFF), waves: rgb(0xFFB020), border: nil),          // ink + amber
    Palette(tile: rgb(0xF3F0E8), letter: rgb(0x17181C), waves: rgb(0x17181C), border: rgb(0x000000, 0.10)), // paper
    Palette(tile: rgb(0x0E7C66), letter: rgb(0xFFFFFF), waves: rgb(0xFFFFFF), border: nil),          // teal
]

/// Letter and waves in their own y-down design space.
func parts() -> (letter: CGPath, waves: CGPath) {
    let letter = CGMutablePath()
    letter.addRoundedRect(in: CGRect(x: 0.385, y: 0.455, width: 0.11, height: 0.335), cornerWidth: 0.055, cornerHeight: 0.055)
    let dot = CGPoint(x: 0.44, y: 0.315)
    letter.addEllipse(in: CGRect(x: dot.x - 0.068, y: dot.y - 0.068, width: 0.136, height: 0.136))
    let arcs = CGMutablePath()
    for radius in [0.16, 0.26] as [CGFloat] {
        let start = -CGFloat.pi * 0.39, end = CGFloat.pi * 0.06
        arcs.move(to: CGPoint(x: dot.x + cos(start) * radius, y: dot.y + sin(start) * radius))
        arcs.addArc(center: dot, radius: radius, startAngle: start, endAngle: end, clockwise: false)
    }
    let waves = arcs.copy(strokingWithWidth: 0.06, lineCap: .round, lineJoin: .round, miterLimit: 10)
    return (letter, waves)
}

/// Both parts scaled together to fit `rect`, optically centred.
func fitted(in rect: CGRect) -> (letter: CGPath, waves: CGPath) {
    let (letter, waves) = parts()
    let union = CGMutablePath()
    union.addPath(letter)
    union.addPath(waves)
    let bounds = union.boundingBoxOfPath
    let scale = min(rect.width / bounds.width, rect.height / bounds.height)
    var transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -bounds.midX, y: -bounds.midY)
    return (letter.copy(using: &transform)!, waves.copy(using: &transform)!)
}

func drawIcon(_ context: CGContext, canvas: CGFloat, palette: Palette) {
    context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)
    let inset = canvas * 0.098
    let tile = CGRect(x: inset, y: inset * 0.92, width: canvas - inset * 2, height: canvas - inset * 2)
    let radius = tile.width * 0.2237
    let shape = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: canvas * 0.01), blur: canvas * 0.025, color: rgb(0x000000, 0.28))
    context.addPath(shape)
    context.setFillColor(palette.tile)
    context.fillPath()
    context.restoreGState()
    if let border = palette.border {
        context.addPath(shape)
        context.setStrokeColor(border)
        context.setLineWidth(max(1, canvas * 0.004))
        context.strokePath()
    }
    let glyph = fitted(in: tile.insetBy(dx: tile.width * 0.25, dy: tile.height * 0.22))
    context.addPath(glyph.letter)
    context.setFillColor(palette.letter)
    context.fillPath()
    context.addPath(glyph.waves)
    context.setFillColor(palette.waves)
    context.fillPath()
}

func png(_ pixels: Int, palette: Palette) -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Icon rendering failed") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawIcon(context.cgContext, canvas: CGFloat(pixels), palette: palette)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon encoding failed") }
    return data
}

let arguments = CommandLine.arguments
let output = URL(fileURLWithPath: arguments[1])
let variant = arguments.count > 2 ? Int(arguments[2]) ?? 0 : 0
let palette = palettes[min(max(variant, 0), palettes.count - 1)]
if output.pathExtension == "png" {
    // Preview: `swift scripts/make-icon.swift preview.png [variant]`
    try png(1024, palette: palette).write(to: output)
    exit(0)
}
let iconset = output.deletingPathExtension().appendingPathExtension("iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try png(size * scale, palette: palette).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(1) }
