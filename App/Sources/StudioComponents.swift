import AppKit

// Building blocks for the Pink voices Studio window. They draw their own surfaces so the
// window reads as one stage-lit product rather than stock grey panels.

/// Window background: deep plum with two soft stage lights and a fine grain.
final class StudioBackdrop: NSView {
    private static let grain: NSImage = {
        let size = 160
        var random = PinkRandom(seed: 3)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        for _ in 0..<2600 {
            let value = random.next()
            NSColor(white: value > 0.5 ? 1 : 0, alpha: 0.05 * random.next()).setFill()
            NSRect(x: random.range(0, CGFloat(size)), y: random.range(0, CGFloat(size)), width: 1, height: 1).fill()
        }
        image.unlockFocus()
        return image
    }()

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let base = PinkTheme.gradient([(PinkTheme.rgb(0x1E1330), 0), (PinkTheme.stage, 0.45), (PinkTheme.ink, 1)]) {
            context.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: bounds.width * 0.3, y: bounds.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let lights: [(NSColor, CGPoint, CGFloat, CGFloat)] = [
            (PinkTheme.hotPink, CGPoint(x: bounds.width * 0.18, y: 40), 420, 0.28),
            (PinkTheme.violet, CGPoint(x: bounds.width * 0.92, y: 120), 380, 0.2),
            (PinkTheme.peach, CGPoint(x: bounds.width * 0.6, y: bounds.height + 60), 360, 0.08)
        ]
        for (color, center, radius, alpha) in lights {
            if let glow = PinkTheme.gradient([(color.withAlphaComponent(alpha), 0), (color.withAlphaComponent(0), 1)]) {
                context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
            }
        }
        NSColor(patternImage: Self.grain).setFill()
        bounds.fill(using: .sourceOver)
    }
}

/// A rounded glass panel with a hairline rim and optional hover lift.
class StudioSurface: NSView {
    var cornerRadius: CGFloat = 18
    var tint: NSColor = PinkTheme.plum
    var emphasis: CGFloat = 0 { didSet { needsDisplay = true } }
    var hoverable = false { didSet { updateTrackingAreas() } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard hoverable else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let lift = (hovering ? 1 : 0) * 0.5 + emphasis
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let fill = PinkTheme.gradient([(tint.withAlphaComponent(0.78 + 0.1 * lift), 0), (PinkTheme.ink.withAlphaComponent(0.72), 1)]) {
            context.drawLinearGradient(fill, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: bounds.height), options: [])
        }
        if let sheen = PinkTheme.gradient([(NSColor.white.withAlphaComponent(0.07 + 0.04 * lift), 0), (NSColor.white.withAlphaComponent(0), 1)]) {
            context.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: min(60, bounds.height)), options: [])
        }
        if lift > 0, let glow = PinkTheme.gradient([(PinkTheme.hotPink.withAlphaComponent(0.16 * lift), 0), (PinkTheme.hotPink.withAlphaComponent(0), 1)]) {
            context.drawRadialGradient(glow, startCenter: CGPoint(x: bounds.width * 0.15, y: 0), startRadius: 0,
                                       endCenter: CGPoint(x: bounds.width * 0.15, y: 0), endRadius: bounds.width * 0.7, options: [])
        }
        context.restoreGState()
        context.addPath(path)
        context.setLineWidth(1)
        context.setStrokeColor(PinkTheme.rose.withAlphaComponent(0.16 + 0.22 * lift).cgColor)
        context.strokePath()
    }
}

/// Capsule button. Primary uses the pink gradient; quiet ones are glass with a rose rim.
final class PinkButton: NSButton {
    enum Style { case primary, quiet }
    var style: Style = .quiet { didSet { needsDisplay = true } }
    /// A larger, glowing call to action (the tutorial button).
    var big = false { didSet { font = PinkTheme.rounded(big ? 16 : 12.5, big ? .heavy : .semibold); invalidateIntrinsicContentSize() } }
    var handler: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    convenience init(_ title: String, style: Style = .quiet, symbol: String? = nil, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.style = style
        self.handler = handler
        isBordered = false
        bezelStyle = .regularSquare
        target = self
        action = #selector(fire)
        font = PinkTheme.rounded(12.5, .semibold)
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); imagePosition = .imageLeading }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @objc private func fire() { handler?() }

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: font ?? PinkTheme.rounded(12.5, .semibold)])
        return NSSize(width: ceil(text.width) + (image == nil ? 30 : 50) + (big ? 26 : 0), height: big ? 46 : 30)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let pressed = isHighlighted
        let rect = bounds.insetBy(dx: pressed ? 2 : 1, dy: pressed ? 2 : 1)
        let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        context.saveGState()
        if style == .primary {
            context.setShadow(offset: CGSize(width: 0, height: -2), blur: (hovering ? 14 : 8) + (big ? 12 : 0), color: PinkTheme.hotPink.withAlphaComponent(hovering || big ? 0.85 : 0.45).cgColor)
            context.addPath(path)
            context.setFillColor(PinkTheme.roseDeep.cgColor)
            context.fillPath()
            context.restoreGState()
            context.saveGState()
            context.addPath(path)
            context.clip()
            let top = hovering ? PinkTheme.rgb(0xFF7DBA) : PinkTheme.rgb(0xFF5FA8)
            if let fill = PinkTheme.gradient([(top, 0), (PinkTheme.roseDeep, 0.6), (PinkTheme.rgb(0xB8337A), 1)]) {
                context.drawLinearGradient(fill, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
            }
            if let gloss = PinkTheme.gradient([(NSColor.white.withAlphaComponent(0.32), 0), (NSColor.white.withAlphaComponent(0), 1)]) {
                context.drawLinearGradient(gloss, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY), options: [])
            }
        } else {
            context.addPath(path)
            context.setFillColor((hovering ? PinkTheme.plumHigh : PinkTheme.plum).withAlphaComponent(hovering ? 0.95 : 0.7).cgColor)
            context.fillPath()
            context.addPath(path)
            context.setLineWidth(1)
            context.setStrokeColor(PinkTheme.rose.withAlphaComponent(hovering ? 0.7 : 0.32).cgColor)
            context.strokePath()
        }
        context.restoreGState()

        let color = isEnabled ? NSColor.white : PinkTheme.textMuted
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? PinkTheme.rounded(12.5, .semibold), .foregroundColor: color]
        let text = NSAttributedString(string: title, attributes: attributes)
        let textSize = text.size()
        var x = bounds.midX - textSize.width / 2
        if let image {
            let configured = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: big ? 16 : 12, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))) ?? image
            let box = configured.size
            x += (box.width + 6) / 2
            configured.draw(in: NSRect(x: x - box.width - 6, y: bounds.midY - box.height / 2, width: box.width, height: box.height))
        }
        text.draw(at: NSPoint(x: x, y: bounds.midY - textSize.height / 2))
    }
}

/// Small status pill: colored dot plus a short word.
final class StatusPill: NSView {
    var text = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(text) } }
    var color: NSColor = PinkTheme.mint { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("code-only") }

    private var attributes: [NSAttributedString.Key: Any] { [.font: PinkTheme.rounded(11.5, .semibold), .foregroundColor: color] }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((text as NSString).size(withAttributes: attributes).width) + 30, height: 22)
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        color.withAlphaComponent(0.14).setFill()
        path.fill()
        color.withAlphaComponent(0.35).setStroke()
        path.stroke()
        let dot = NSRect(x: 9, y: bounds.midY - 3, width: 6, height: 6)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowBlurRadius = 5
        shadow.set()
        color.setFill()
        NSBezierPath(ovalIn: dot).fill()
        NSGraphicsContext.restoreGraphicsState()
        let string = NSAttributedString(string: text, attributes: attributes)
        string.draw(at: NSPoint(x: 21, y: bounds.midY - string.size().height / 2))
    }
}

/// A 3D keycap showing the hold-to-talk key. It sinks while the hero demo is listening.
final class KeycapView: NSView {
    var glyph = "⌥" { didSet { needsDisplay = true } }
    var caption = "Option ขวา" { didSet { needsDisplay = true; setAccessibilityLabel("ปุ่มกดค้าง \(caption)") } }
    var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("code-only") }
    override var intrinsicContentSize: NSSize { NSSize(width: 92, height: 74) }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let depth: CGFloat = pressed ? 2 : 7
        let base = NSRect(x: 4, y: 10, width: bounds.width - 8, height: bounds.height - 16)
        let top = NSRect(x: base.minX, y: base.minY - depth + 7, width: base.width, height: base.height - 7)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 6), blur: pressed ? 22 : 12,
                          color: (pressed ? PinkTheme.hotPink.withAlphaComponent(0.8) : NSColor.black.withAlphaComponent(0.5)).cgColor)
        let skirt = CGPath(roundedRect: base, cornerWidth: 14, cornerHeight: 14, transform: nil)
        context.addPath(skirt)
        context.setFillColor(PinkTheme.rgb(0x7A1E52).cgColor)
        context.fillPath()
        context.restoreGState()

        let face = CGPath(roundedRect: top, cornerWidth: 13, cornerHeight: 13, transform: nil)
        context.saveGState()
        context.addPath(face)
        context.clip()
        let colors: [(NSColor, CGFloat)] = pressed
            ? [(PinkTheme.rgb(0xFF8AC2), 0), (PinkTheme.hotPink, 0.55), (PinkTheme.roseDeep, 1)]
            : [(PinkTheme.rgb(0x4A2A62), 0), (PinkTheme.plumHigh, 0.5), (PinkTheme.plum, 1)]
        if let gradient = PinkTheme.gradient(colors) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top.minY), end: CGPoint(x: 0, y: top.maxY), options: [])
        }
        if let gloss = PinkTheme.gradient([(NSColor.white.withAlphaComponent(0.28), 0), (NSColor.white.withAlphaComponent(0), 1)]) {
            context.drawLinearGradient(gloss, start: CGPoint(x: 0, y: top.minY), end: CGPoint(x: 0, y: top.minY + 22), options: [])
        }
        context.restoreGState()
        context.addPath(face)
        context.setLineWidth(1)
        context.setStrokeColor(PinkTheme.rose.withAlphaComponent(pressed ? 0.9 : 0.45).cgColor)
        context.strokePath()

        let glyphText = NSAttributedString(string: glyph, attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white])
        let glyphSize = glyphText.size()
        glyphText.draw(at: NSPoint(x: top.midX - glyphSize.width / 2, y: top.minY + 7))
        let captionText = NSAttributedString(string: caption, attributes: [.font: PinkTheme.rounded(10.5, .semibold), .foregroundColor: PinkTheme.blush.withAlphaComponent(0.9)])
        let captionSize = captionText.size()
        captionText.draw(at: NSPoint(x: top.midX - captionSize.width / 2, y: top.maxY - captionSize.height - 6))
    }
}

/// Text helpers with the Studio palette.
enum StudioText {
    static func label(_ text: String, _ font: NSFont, _ color: NSColor = PinkTheme.textPrimary) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func wrapping(_ text: String, _ font: NSFont, _ color: NSColor = PinkTheme.textSecondary, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.preferredMaxLayoutWidth = width
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        return field
    }

    static func eyebrow(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: NSAttributedString(string: text.uppercased(), attributes: [
            .font: PinkTheme.rounded(11, .heavy), .foregroundColor: PinkTheme.rose, .kern: 1.6
        ]))
        return field
    }
}
