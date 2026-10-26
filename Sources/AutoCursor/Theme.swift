import AppKit
import SwiftUI

enum Theme {
    static let indigo = Color(red: 0.38, green: 0.36, blue: 0.98)
    static let violet = Color(red: 0.69, green: 0.36, blue: 0.97)
    static let gradient = LinearGradient(colors: [indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let success = Color(red: 0.20, green: 0.80, blue: 0.47)
    static let warning = Color(red: 1.00, green: 0.62, blue: 0.20)
}

enum AppIcon {
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    /// A bitmap the Dock can snapshot. The drawing-handler image above stays blank in the Dock and falls back to the generic app icon.
    static func dockImage() -> NSImage {
        guard let data = pngData(pixels: 1024), let image = NSImage(data: data) else { return image(size: 512) }
        image.size = NSSize(width: 512, height: 512)
        return image
    }

    static func pngData(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func exportIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 1 ? "" : "@2x"
                guard let data = pngData(pixels: base * scale) else { continue }
                try data.write(to: directory.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
            }
        }
    }

    private static func draw(in rect: NSRect) {
        let side = rect.width
        // Matches the macOS icon grid: 824pt body inside a 1024pt canvas.
        let body = rect.insetBy(dx: side * 0.098, dy: side * 0.098)
        let radius = body.width * 0.225
        let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = side * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -side * 0.012)
        shadow.set()
        NSColor(red: 0.38, green: 0.36, blue: 0.98, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(colors: [
            NSColor(red: 0.30, green: 0.40, blue: 1.00, alpha: 1),
            NSColor(red: 0.47, green: 0.33, blue: 0.98, alpha: 1),
            NSColor(red: 0.76, green: 0.36, blue: 0.95, alpha: 1),
        ])?.draw(in: shape, angle: -55)

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let gloss = NSBezierPath(ovalIn: NSRect(x: body.minX - body.width * 0.25, y: body.midY,
                                                width: body.width * 1.5, height: body.height * 0.95))
        NSColor.white.withAlphaComponent(0.12).setFill()
        gloss.fill()
        NSGraphicsContext.restoreGraphicsState()

        let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.40, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let symbolSize = symbol.size
        let symbolRect = NSRect(x: body.midX - symbolSize.width / 2 + side * 0.01,
                                y: body.midY - symbolSize.height / 2,
                                width: symbolSize.width, height: symbolSize.height)
        NSGraphicsContext.saveGraphicsState()
        let symbolShadow = NSShadow()
        symbolShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        symbolShadow.shadowBlurRadius = side * 0.02
        symbolShadow.shadowOffset = NSSize(width: 0, height: -side * 0.01)
        symbolShadow.set()
        symbol.draw(in: symbolRect)
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .frame(width: 16, height: 16)
    }
}

struct Card<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.map { $0.opacity(0.10) } ?? Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.map { $0.opacity(0.30) } ?? Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}
