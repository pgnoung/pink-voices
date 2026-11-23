import AppKit

/// Shared Pink voices palette and type. Colors follow the Pink Cuts stage
/// (#1C1828) and rose (#E2528A / #F391A9) with a violet and peach counterpoint.
enum PinkTheme {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    static let stage = rgb(0x1C1828)
    static let ink = rgb(0x120A1C)
    static let plum = rgb(0x2B1838)
    static let plumHigh = rgb(0x3A2150)
    static let rose = rgb(0xF391A9)
    static let roseDeep = rgb(0xE2528A)
    static let hotPink = rgb(0xFF4FA3)
    static let blush = rgb(0xFFE3EF)
    static let violet = rgb(0x9B6BFF)
    static let peach = rgb(0xFFB38A)
    static let coral = rgb(0xFF6B78)
    static let mint = rgb(0x7CF0C8)
    static let amber = rgb(0xFFC861)
    static let textPrimary = NSColor.white
    static let textSecondary = rgb(0xF6D3E0, 0.78)
    static let textMuted = rgb(0xD9B8CA, 0.55)
    static let hairline = rgb(0xF391A9, 0.22)

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// The build's credit line (Info.plist PVCredit), with any heart tinted pink. Nil when unset.
    static func credit(size: CGFloat = 12) -> NSAttributedString? {
        guard let line = Brand.credit, !line.isEmpty else { return nil }
        let base: [NSAttributedString.Key: Any] = [.font: rounded(size, .semibold), .foregroundColor: textSecondary]
        let text = NSMutableAttributedString()
        for (index, part) in line.components(separatedBy: "♥").enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "♥", attributes: [.font: rounded(size + 1, .bold), .foregroundColor: hotPink])) }
            text.append(NSAttributedString(string: part, attributes: base))
        }
        return text
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    /// Dark plum chrome for the app's own windows, so editors and alerts read as one product.
    static func style(_ window: NSWindow) {
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = stage
    }

    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let x = a.usingColorSpace(.sRGB) ?? a, y = b.usingColorSpace(.sRGB) ?? b
        let k = min(max(t, 0), 1)
        return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * k,
                       green: x.greenComponent + (y.greenComponent - x.greenComponent) * k,
                       blue: x.blueComponent + (y.blueComponent - x.blueComponent) * k,
                       alpha: x.alphaComponent + (y.alphaComponent - x.alphaComponent) * k)
    }

    static func gradient(_ stops: [(NSColor, CGFloat)]) -> CGGradient? {
        let colors = stops.map { ($0.0.usingColorSpace(.sRGB) ?? $0.0).cgColor } as CFArray
        let locations = stops.map(\.1)
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations)
    }
}

/// Small deterministic generator so previews and rendered movies are repeatable.
struct PinkRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
    }
    mutating func range(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + (high - low) * next() }
}
