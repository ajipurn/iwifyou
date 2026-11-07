import AppKit
import SwiftUI

/// The iwifyou mark: a lowercase "i" whose dot broadcasts two signal waves,
/// ink tile, white letter, amber waves. Flat colours only.
/// Keep in sync with scripts/make-icon.swift (palette 0), which draws the app icon.
nonisolated enum LogoGeometry {
    static func parts() -> (letter: CGPath, waves: CGPath) {
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
        return (letter, arcs.copy(strokingWithWidth: 0.06, lineCap: .round, lineJoin: .round, miterLimit: 10))
    }

    /// Both parts scaled together to fit `rect` (y-down), centred.
    static func fitted(in rect: CGRect) -> (letter: CGPath, waves: CGPath) {
        let (letter, waves) = parts()
        let union = CGMutablePath()
        union.addPath(letter)
        union.addPath(waves)
        let bounds = union.boundingBoxOfPath
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        var transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        return (letter.copy(using: &transform) ?? letter, waves.copy(using: &transform) ?? waves)
    }

    /// The glyph area inside a tile, matching the app icon.
    static func glyphRect(in tile: CGRect) -> CGRect {
        tile.insetBy(dx: tile.width * 0.25, dy: tile.height * 0.22)
    }

    /// Monochrome template image for the menu bar.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let glyph = fitted(in: rect.insetBy(dx: 2, dy: 1))
            context.addPath(glyph.letter)
            context.addPath(glyph.waves)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "iwifyou"
        return image
    }
}

nonisolated struct LogoLetter: Shape {
    func path(in rect: CGRect) -> Path { Path(LogoGeometry.fitted(in: rect).letter) }
}

nonisolated struct LogoWaves: Shape {
    func path(in rect: CGRect) -> Path { Path(LogoGeometry.fitted(in: rect).waves) }
}

struct LogoMark: View {
    var size: CGFloat = 32

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        ZStack {
            tile.fill(Brand.logoInk)
            Group {
                LogoLetter().fill(.white)
                LogoWaves().fill(Brand.amber)
            }
            .padding(.horizontal, size * 0.25)
            .padding(.vertical, size * 0.22)
        }
        .overlay(tile.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
