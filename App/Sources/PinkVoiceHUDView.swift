import AppKit
import QuartzCore

/// The capsule that appears while dictating. Everything is drawn with Core Graphics from
/// a time-stepped model, so the live panel, the Studio showcase and offline renders are the
/// same picture. Motion is decorative only and stops under Reduce Motion.
final class PinkVoiceHUDView: NSView {
    static let canvasSize = NSSize(width: 600, height: 196)
    static let pillSize = NSSize(width: 448, height: 82)
    static let pillBottom: CGFloat = 46
    private static let barCount = 36

    private(set) var state: PinkVoiceHUD.State = .recording
    /// Studio embedding: plays a scripted loop and never posts accessibility announcements.
    var showcase = false { didSet { if showcase { demo = DemoScript() } } }
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private var history = [CGFloat](repeating: 0, count: barCount)
    private var bars = [CGFloat](repeating: 0, count: barCount)
    private var energy: CGFloat = 0
    private var time: CFTimeInterval = 0
    private var stateTime: CFTimeInterval = 0
    private var shownAt: CFTimeInterval = 0
    private var recordingStarted: CFTimeInterval = 0
    private var appear: CGFloat = 0
    private var appearVelocity: CGFloat = 0
    private var particles = [Particle]()
    private var spawnCarry: CGFloat = 0
    private var random = PinkRandom(seed: 7)
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var lastAnnouncedState: PinkVoiceHUD.State?
    private var demo: DemoScript?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("PinkVoiceHUDView is code-only") }
    deinit { timer?.invalidate() }
    override var isOpaque: Bool { false }
    override func accessibilityLabel() -> String? { "\(Brand.name): \(state.message)" }

    // MARK: Model

    func present(_ nextState: PinkVoiceHUD.State, level: CGFloat) {
        let stateChanged = nextState != state
        if stateChanged || lastAnnouncedState == nil { stateTime = 0 }
        if nextState == .recording && (stateChanged || lastAnnouncedState == nil) { recordingStarted = time }
        state = nextState
        if state == .recording {
            history = Array(repeating: min(max(level, 0), 1), count: history.count)
        }
        if stateChanged && (state == .inserted || state == .localFallback || state == .learned) { burst() }
        if stateChanged || lastAnnouncedState == nil {
            lastAnnouncedState = state
            if !showcase {
                NSAccessibility.post(element: self, notification: .announcementRequested,
                                     userInfo: [.announcement: state.message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
        startAnimation()
        needsDisplay = true
    }

    /// Resets the entrance spring. Called each time the panel is ordered in.
    func beginAppearance() {
        appear = 0
        appearVelocity = 0
        shownAt = time
        particles.removeAll()
    }

    func push(level: CGFloat) {
        history.removeFirst()
        history.append(min(max(level, 0), 1))
        needsDisplay = true
    }

    func stopAnimation() { timer?.invalidate(); timer = nil }

    private func startAnimation() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 0), 1.0 / 20.0)
        lastTick = now
        step(dt)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimation() } else if showcase { startAnimation() }
    }

    /// Advances springs, bars and particles by `dt` seconds.
    func step(_ dt: CFTimeInterval) {
        if var script = demo {
            script.advance(dt, into: self)
            demo = script
        }
        time += dt
        stateTime += dt
        let delta = CGFloat(dt)

        if reduceMotion {
            appear = 1; appearVelocity = 0
        } else {
            let force = 210 * (1 - appear) - 17 * appearVelocity
            appearVelocity += force * delta
            appear += appearVelocity * delta
        }

        let targetEnergy = state == .recording ? (history.suffix(4).max() ?? 0) : 0
        energy += (targetEnergy - energy) * min(1, delta * (targetEnergy > energy ? 16 : 6))

        for index in bars.indices {
            let target = barTarget(index)
            bars[index] += (target - bars[index]) * min(1, delta * 20)
        }
        stepParticles(delta)
    }

    private func barTarget(_ index: Int) -> CGFloat {
        let position = CGFloat(index) / CGFloat(Self.barCount - 1)
        let motion = reduceMotion ? 0 : CGFloat(time)
        switch state {
        case .recording:
            let sample = history[index]
            return sample < 0.012 ? 0 : pow(sample, 0.72)
        case .finishing, .waiting:
            return 0.16 + 0.34 * (0.5 + 0.5 * sin(motion * 6.2 - CGFloat(index) * 0.44))
        case .checking:
            let scan = 0.5 + 0.5 * sin(motion * 2.4)
            let distance = (position - scan) / 0.14
            return 0.1 + 0.72 * exp(-distance * distance) + 0.06 * sin(motion * 9 + CGFloat(index))
        default:
            return 0
        }
    }

    // MARK: Particles

    private struct Particle {
        var point: CGPoint
        var velocity: CGVector
        var life: CGFloat
        var maxLife: CGFloat
        var size: CGFloat
        var tint: Int
        var star: Bool
    }

    private func stepParticles(_ delta: CGFloat) {
        guard !reduceMotion else { particles.removeAll(); return }
        if state == .recording && energy > 0.14 {
            spawnCarry += delta * (6 + 46 * energy)
            while spawnCarry >= 1 {
                spawnCarry -= 1
                let angle = random.range(.pi * 0.12, .pi * 0.88)
                let speed = random.range(26, 70) * (0.7 + energy)
                let origin = CGPoint(x: orbCenterLocal.x + cos(angle) * 22, y: orbCenterLocal.y + sin(angle) * 22)
                particles.append(Particle(point: origin, velocity: CGVector(dx: cos(angle) * speed * 1.4, dy: sin(angle) * speed),
                                          life: 0, maxLife: random.range(0.6, 1.25), size: random.range(1.2, 3.2),
                                          tint: Int(random.range(0, 2.99)), star: random.next() > 0.72))
            }
        }
        let drag = pow(0.18, delta)
        particles = particles.compactMap { particle in
            var next = particle
            next.life += delta
            guard next.life < next.maxLife else { return nil }
            next.velocity.dx *= drag
            next.velocity.dy = next.velocity.dy * drag + 18 * delta
            next.point.x += next.velocity.dx * delta
            next.point.y += next.velocity.dy * delta
            return next
        }
        if particles.count > 140 { particles.removeFirst(particles.count - 140) }
    }

    private func burst() {
        guard !reduceMotion else { return }
        for index in 0..<34 {
            let angle = CGFloat(index) / 34 * .pi * 2 + random.range(-0.1, 0.1)
            let speed = random.range(70, 190)
            let origin = CGPoint(x: orbCenterLocal.x + cos(angle) * 24, y: orbCenterLocal.y + sin(angle) * 24)
            particles.append(Particle(point: origin, velocity: CGVector(dx: cos(angle) * speed * 1.3, dy: sin(angle) * speed),
                                      life: 0, maxLife: random.range(0.55, 1.05), size: random.range(1.4, 3.6),
                                      tint: index % 3, star: index % 4 == 0))
        }
    }

    // MARK: Geometry

    private var orbCenterLocal: CGPoint { CGPoint(x: 44, y: Self.pillSize.height / 2) }

    private func pillRect(in bounds: NSRect) -> NSRect {
        let scale = min(bounds.width / Self.canvasSize.width, bounds.height / Self.canvasSize.height)
        let size = NSSize(width: Self.pillSize.width * scale, height: Self.pillSize.height * scale)
        let bottom = bounds.minY + Self.pillBottom * scale + (bounds.height - Self.canvasSize.height * scale) / 2
        return NSRect(x: bounds.midX - size.width / 2, y: bottom, width: size.width, height: size.height)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let canvasScale = min(bounds.width / Self.canvasSize.width, bounds.height / Self.canvasSize.height)
        let pill = pillRect(in: bounds)
        let fade = reduceMotion ? 1 : min(1, CGFloat(time - shownAt) / 0.2)
        let pop = 0.9 + 0.1 * appear
        let shake = isFailure && !reduceMotion ? sin(CGFloat(stateTime) * 46) * 7 * exp(-CGFloat(stateTime) * 6) : 0

        context.saveGState()
        context.setAlpha(fade)
        context.translateBy(x: pill.minX + shake, y: pill.minY)
        context.scaleBy(x: canvasScale, y: canvasScale)
        let local = CGRect(origin: .zero, size: Self.pillSize)
        context.translateBy(x: local.midX, y: local.midY)
        context.scaleBy(x: pop, y: pop)
        context.translateBy(x: -local.midX, y: -local.midY)

        drawAurora(context, local)
        drawBody(context, local)
        drawWave(context, CGRect(x: local.maxX - 26 - 150, y: 12, width: 150, height: local.height - 24))
        drawParticles(context)
        drawOrb(context, center: orbCenterLocal)
        drawText(local)
        context.restoreGState()
    }

    private var isFailure: Bool { [.failed, .timedOut, .noSpeech, .checkField].contains(state) }
    private var isSuccess: Bool { [.inserted, .localFallback, .savedForCopy, .learned].contains(state) }
    private var isWorking: Bool { [.finishing, .waiting, .checking].contains(state) }

    private var accent: NSColor {
        if isFailure { return PinkTheme.coral }
        if state == .cancelled { return PinkTheme.textMuted }
        return PinkTheme.hotPink
    }

    private func drawAurora(_ context: CGContext, _ pill: CGRect) {
        let motion = reduceMotion ? 0 : CGFloat(time)
        let pulse = isWorking ? 0.18 + 0.1 * sin(motion * 3.2) : 0
        let strength = 0.5 + 0.75 * energy + pulse + (isSuccess ? 0.3 * exp(-CGFloat(stateTime) * 2.4) : 0)
        // Elliptical blobs stay inside the transparent panel so no light is ever cut by its edge.
        let lift = 58 + 18 * energy
        let blobs: [(NSColor, CGPoint, CGFloat, CGFloat)] = [
            (accent, CGPoint(x: 70 + 12 * sin(motion * 0.9), y: pill.midY + 4 * cos(motion * 1.3)), lift, 1.9),
            (isFailure ? PinkTheme.peach : PinkTheme.violet, CGPoint(x: pill.midX + 50 * sin(motion * 0.55), y: pill.midY + 6), lift, 2.4),
            (PinkTheme.peach, CGPoint(x: pill.maxX - 70 + 12 * cos(motion * 0.8), y: pill.midY - 2), lift * 0.9, 1.8)
        ]
        for (color, center, radius, stretch) in blobs {
            guard let gradient = PinkTheme.gradient([(color.withAlphaComponent(min(0.62, 0.4 * strength)), 0),
                                                     (color.withAlphaComponent(min(0.26, 0.15 * strength)), 0.5),
                                                     (color.withAlphaComponent(0), 1)]) else { continue }
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: stretch, y: 1)
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
            context.restoreGState()
        }
        // Stage light spilling under the capsule.
        context.saveGState()
        context.translateBy(x: pill.midX, y: pill.minY - 4)
        context.scaleBy(x: 6.4, y: 1)
        if let floor = PinkTheme.gradient([(accent.withAlphaComponent(min(0.6, 0.26 + 0.34 * energy + pulse * 0.5)), 0), (accent.withAlphaComponent(0), 1)]) {
            context.drawRadialGradient(floor, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 30 + 6 * energy, options: [])
        }
        context.restoreGState()
    }

    private func drawBody(_ context: CGContext, _ pill: CGRect) {
        let path = CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)
        let motion = reduceMotion ? 0 : CGFloat(time)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        context.addPath(path)
        context.setFillColor(PinkTheme.ink.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        if let body = PinkTheme.gradient([(PinkTheme.plumHigh, 0), (PinkTheme.plum, 0.45), (PinkTheme.ink, 1)]) {
            context.drawLinearGradient(body, start: CGPoint(x: 0, y: pill.maxY), end: CGPoint(x: 0, y: pill.minY), options: [])
        }
        let glowCenter = orbCenterLocal
        if let glow = PinkTheme.gradient([(accent.withAlphaComponent(0.38 + 0.4 * energy), 0), (accent.withAlphaComponent(0), 1)]) {
            context.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: 120 + 60 * energy, options: [])
        }
        if isWorking && !reduceMotion {
            let travel = (motion * 0.85).truncatingRemainder(dividingBy: 1)
            let x = -120 + travel * (pill.width + 240)
            if let sheen = PinkTheme.gradient([(NSColor.white.withAlphaComponent(0), 0), (NSColor.white.withAlphaComponent(0.13), 0.5), (NSColor.white.withAlphaComponent(0), 1)]) {
                context.drawLinearGradient(sheen, start: CGPoint(x: x - 60, y: pill.minY), end: CGPoint(x: x + 60, y: pill.maxY), options: [])
            }
        }
        if let gloss = PinkTheme.gradient([(NSColor.white.withAlphaComponent(0.14), 0), (NSColor.white.withAlphaComponent(0), 1)]) {
            context.drawLinearGradient(gloss, start: CGPoint(x: 0, y: pill.maxY), end: CGPoint(x: 0, y: pill.midY + 4), options: [])
        }
        if let underlight = PinkTheme.gradient([(accent.withAlphaComponent(0.22 + 0.25 * energy), 0), (accent.withAlphaComponent(0), 1)]) {
            context.drawLinearGradient(underlight, start: CGPoint(x: 0, y: pill.minY), end: CGPoint(x: 0, y: pill.minY + 18), options: [])
        }
        context.restoreGState()

        // Outer neon line, brighter as the voice gets louder.
        context.saveGState()
        context.setShadow(offset: .zero, blur: 12 + 20 * energy, color: accent.withAlphaComponent(0.55 + 0.4 * energy).cgColor)
        context.addPath(path)
        context.setLineWidth(1.2)
        context.setStrokeColor(accent.withAlphaComponent(0.35).cgColor)
        context.strokePath()
        context.restoreGState()

        // Rotating gradient rim.
        context.saveGState()
        context.addPath(path)
        context.setLineWidth(1.6)
        context.replacePathWithStrokedPath()
        context.clip()
        let angle = motion * 0.9
        let center = CGPoint(x: pill.midX, y: pill.midY)
        let reach = pill.width / 2
        let rim: [(NSColor, CGFloat)] = isFailure
            ? [(PinkTheme.coral, 0), (PinkTheme.peach, 0.5), (PinkTheme.coral, 1)]
            : [(PinkTheme.rose, 0), (PinkTheme.violet, 0.32), (PinkTheme.blush, 0.55), (PinkTheme.hotPink, 0.78), (PinkTheme.peach, 1)]
        if let gradient = PinkTheme.gradient(rim) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach * 0.5),
                                       end: CGPoint(x: center.x - cos(angle) * reach, y: center.y - sin(angle) * reach * 0.5),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.restoreGState()
    }

    private func drawOrb(_ context: CGContext, center: CGPoint) {
        let motion = reduceMotion ? 0 : CGFloat(time)
        let breathe = reduceMotion ? 0 : 0.035 * sin(motion * 3)
        let successPop = isSuccess ? 0.22 * exp(-CGFloat(stateTime) * 7) * sin(CGFloat(stateTime) * 18) : 0
        let radius = 19 * (1 + 0.2 * energy + breathe + successPop)

        if state == .recording && !reduceMotion {
            for ring in 0..<3 {
                let progress = (motion * 0.75 + CGFloat(ring) / 3).truncatingRemainder(dividingBy: 1)
                let r = radius + progress * (14 + 30 * energy)
                context.setStrokeColor(PinkTheme.hotPink.withAlphaComponent((1 - progress) * (0.18 + 0.62 * energy)).cgColor)
                context.setLineWidth(1.4)
                context.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            }
        }
        if isSuccess {
            let progress = min(1, CGFloat(stateTime) / 0.7)
            let r = radius + progress * 46
            context.setStrokeColor(PinkTheme.blush.withAlphaComponent((1 - progress) * 0.8).cgColor)
            context.setLineWidth(2.2 * (1 - progress) + 0.4)
            context.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }

        let core: [(NSColor, CGFloat)]
        if isFailure {
            core = [(PinkTheme.rgb(0xFFE1DC), 0), (PinkTheme.coral, 0.55), (PinkTheme.rgb(0xB8323F), 1)]
        } else if state == .cancelled {
            core = [(PinkTheme.rgb(0xEBDDE6), 0), (PinkTheme.rgb(0x9C8496), 0.6), (PinkTheme.rgb(0x5A4458), 1)]
        } else {
            core = [(PinkTheme.blush, 0), (PinkTheme.rgb(0xFF72B4), 0.5), (PinkTheme.rgb(0xB82C7A), 1)]
        }
        context.saveGState()
        context.setShadow(offset: .zero, blur: 16 + 22 * energy, color: accent.withAlphaComponent(0.9).cgColor)
        context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.setFillColor(accent.cgColor)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.clip()
        if let gradient = PinkTheme.gradient(core) {
            let focus = CGPoint(x: center.x - radius * 0.35, y: center.y + radius * 0.4)
            context.drawRadialGradient(gradient, startCenter: focus, startRadius: 0, endCenter: center, endRadius: radius * 1.05, options: [.drawsAfterEndLocation])
        }
        context.setFillColor(NSColor.white.withAlphaComponent(0.38).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius * 0.55, y: center.y + radius * 0.22, width: radius * 0.6, height: radius * 0.38))
        context.restoreGState()

        if isWorking {
            let spin = reduceMotion ? 0.6 : motion * 4.2
            let r = radius + 7
            context.saveGState()
            context.setLineCap(.round)
            context.setLineWidth(2.4)
            context.setShadow(offset: .zero, blur: 8, color: PinkTheme.hotPink.cgColor)
            context.setStrokeColor(PinkTheme.blush.cgColor)
            context.addArc(center: center, radius: r, startAngle: spin, endAngle: spin + 1.9, clockwise: false)
            context.strokePath()
            context.setStrokeColor(PinkTheme.violet.cgColor)
            context.addArc(center: center, radius: r, startAngle: spin + .pi, endAngle: spin + .pi + 1.1, clockwise: false)
            context.strokePath()
            context.restoreGState()
            for dot in 0..<3 {
                let a = -spin * 0.7 + CGFloat(dot) * .pi * 2 / 3
                let point = CGPoint(x: center.x + cos(a) * (r + 7), y: center.y + sin(a) * (r + 7))
                context.setFillColor(PinkTheme.peach.withAlphaComponent(0.9).cgColor)
                context.fillEllipse(in: CGRect(x: point.x - 1.6, y: point.y - 1.6, width: 3.2, height: 3.2))
            }
        }

        if isSuccess && state != .savedForCopy {
            drawCheck(context, center: center, progress: reduceMotion ? 1 : min(1, CGFloat(stateTime) / 0.32))
        } else {
            drawSymbol(center: center, size: 15 + 3 * energy)
        }
    }

    private func drawCheck(_ context: CGContext, center: CGPoint, progress: CGFloat) {
        let points = [CGPoint(x: center.x - 8, y: center.y + 0.5), CGPoint(x: center.x - 2.5, y: center.y - 5.5), CGPoint(x: center.x + 8.5, y: center.y + 6.5)]
        let first = hypot(points[1].x - points[0].x, points[1].y - points[0].y)
        let second = hypot(points[2].x - points[1].x, points[2].y - points[1].y)
        let travelled = (first + second) * progress
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(3.2)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: PinkTheme.roseDeep.cgColor)
        context.move(to: points[0])
        if travelled <= first {
            let t = travelled / first
            context.addLine(to: CGPoint(x: points[0].x + (points[1].x - points[0].x) * t, y: points[0].y + (points[1].y - points[0].y) * t))
        } else {
            let t = (travelled - first) / second
            context.addLine(to: points[1])
            context.addLine(to: CGPoint(x: points[1].x + (points[2].x - points[1].x) * t, y: points[1].y + (points[2].y - points[1].y) * t))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawSymbol(center: CGPoint, size: CGFloat) {
        guard let image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: state.message) else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let symbol = image.withSymbolConfiguration(configuration) ?? image
        let box = symbol.size
        symbol.draw(in: NSRect(x: center.x - box.width / 2, y: center.y - box.height / 2, width: box.width, height: box.height),
                    from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func drawText(_ pill: CGRect) {
        let left: CGFloat = 82
        let width = pill.maxX - 26 - 150 - 10 - left
        let title = NSAttributedString(string: state.message, attributes: [
            .font: PinkTheme.rounded(16, .bold), .foregroundColor: NSColor.white,
            .kern: 0.1
        ])
        let subtitleColor = isFailure ? PinkTheme.rgb(0xFFC9C4, 0.9) : PinkTheme.textSecondary
        let subtitle = NSAttributedString(string: subtitleText, attributes: [
            .font: state == .recording ? PinkTheme.mono(11.5, .semibold) : PinkTheme.rounded(11.5, .medium),
            .foregroundColor: subtitleColor
        ])
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        title.draw(with: NSRect(x: left, y: pill.midY + 1, width: width, height: 22), options: options)
        subtitle.draw(with: NSRect(x: left, y: pill.midY - 19, width: width, height: 17), options: options)
    }

    private var subtitleText: String {
        switch state {
        case .recording:
            let seconds = max(0, Int(time - recordingStarted))
            return String(format: "%d:%02d", seconds / 60, seconds % 60) + "  ·  ปล่อยปุ่มเพื่อใส่ข้อความ"
        case .finishing: return "Local AI บน Mac"
        case .waiting: return "อีกนิดเดียว"
        case .checking: return "ตรวจชื่อแบรนด์และการสะกด"
        case .localFallback: return "ใช้ผลในเครื่องแทน"
        case .inserted: return "อยู่ในช่องพิมพ์แล้ว"
        case .checkField: return "คลิกช่องพิมพ์แล้วลองอีกครั้ง"
        case .savedForCopy: return "เลือกคัดลอกจากเมนู"
        case .cancelled: return "ไม่ได้ใส่ข้อความ"
        case .failed: return "ลองพูดอีกครั้ง"
        case .noSpeech: return "ลองพูดใกล้ไมค์ขึ้น"
        case .timedOut: return "ลองพูดสั้นลงอีกครั้ง"
        case .learned: return "ครั้งหน้าจะสะกดให้ถูกเอง"
        }
    }

    private func drawWave(_ context: CGContext, _ rect: CGRect) {
        let count = Self.barCount
        let step = rect.width / CGFloat(count)
        let barWidth: CGFloat = 2.7
        let motion = reduceMotion ? 0 : CGFloat(time)
        let scan = 0.5 + 0.5 * sin(motion * 2.4)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 7 + 10 * energy, color: accent.withAlphaComponent(0.85).cgColor)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for index in 0..<count {
            let position = CGFloat(index) / CGFloat(count - 1)
            let value = bars[index]
            let height = max(3, 3 + value * (rect.height - 3))
            let x = rect.minX + CGFloat(index) * step + (step - barWidth) / 2
            let bar = CGRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
            var color: NSColor
            if isFailure {
                color = PinkTheme.mix(PinkTheme.coral, PinkTheme.peach, position)
            } else if state == .cancelled {
                color = PinkTheme.textMuted
            } else {
                color = position < 0.5 ? PinkTheme.mix(PinkTheme.violet, PinkTheme.hotPink, position * 2)
                                       : PinkTheme.mix(PinkTheme.hotPink, PinkTheme.blush, (position - 0.5) * 2)
            }
            if state == .checking {
                let distance = abs(position - scan)
                color = PinkTheme.mix(color, .white, max(0, 1 - distance / 0.12) * 0.8)
            }
            let fadeIn = state == .recording ? 0.35 + 0.65 * position : 0.85
            context.setFillColor(color.withAlphaComponent(fadeIn).cgColor)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
            context.fillPath()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func drawParticles(_ context: CGContext) {
        let tints = [PinkTheme.blush, PinkTheme.hotPink, PinkTheme.peach]
        for particle in particles {
            let fade = 1 - particle.life / particle.maxLife
            let alpha = min(1, fade * 1.4)
            let color = tints[particle.tint].withAlphaComponent(alpha)
            let size = particle.size * (0.6 + 0.6 * fade)
            context.saveGState()
            context.setShadow(offset: .zero, blur: 6, color: tints[particle.tint].cgColor)
            context.setFillColor(color.cgColor)
            if particle.star {
                let p = particle.point, s = size * 2.4
                context.move(to: CGPoint(x: p.x, y: p.y + s))
                context.addQuadCurve(to: CGPoint(x: p.x + s, y: p.y), control: p)
                context.addQuadCurve(to: CGPoint(x: p.x, y: p.y - s), control: p)
                context.addQuadCurve(to: CGPoint(x: p.x - s, y: p.y), control: p)
                context.addQuadCurve(to: CGPoint(x: p.x, y: p.y + s), control: p)
                context.fillPath()
            } else {
                context.fillEllipse(in: CGRect(x: particle.point.x - size / 2, y: particle.point.y - size / 2, width: size, height: size))
            }
            context.restoreGState()
        }
    }

    // MARK: Offline rendering

    /// Renders the current frame into a PNG-ready bitmap at 2x.
    func snapshot() -> NSBitmapImageRep? {
        let pixels = NSSize(width: bounds.width * 2, height: bounds.height * 2)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        displayIgnoringOpacity(bounds, in: NSGraphicsContext.current!)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    /// Settles springs and bars as if the panel had been visible for `seconds`.
    func settle(for seconds: CFTimeInterval) {
        stopAnimation()
        var remaining = seconds
        while remaining > 0 { step(1.0 / 60.0); remaining -= 1.0 / 60.0 }
    }

    // MARK: Showcase script

    /// A repeating sequence used by the Studio hero and the rendered demo movie.
    struct DemoScript {
        static let timeline: [(PinkVoiceHUD.State, CFTimeInterval)] = [
            (.recording, 3.4), (.finishing, 0.9), (.checking, 1.3), (.inserted, 1.8)
        ]
        static var duration: CFTimeInterval { timeline.reduce(0) { $0 + $1.1 } }
        private var clock: CFTimeInterval = -1
        private var meterCarry: CFTimeInterval = 0
        private var noise = PinkRandom(seed: 11)

        mutating func advance(_ dt: CFTimeInterval, into view: PinkVoiceHUDView) {
            let previous = clock
            clock += dt
            if previous < 0 { clock = 0 }
            let cycle = clock.truncatingRemainder(dividingBy: Self.duration)
            if previous >= 0 && cycle < previous.truncatingRemainder(dividingBy: Self.duration) { view.beginAppearance() }
            var cursor: CFTimeInterval = 0
            var current = Self.timeline[0].0
            for (state, length) in Self.timeline {
                if cycle < cursor + length { current = state; break }
                cursor += length
            }
            if current != view.state || previous < 0 { view.present(current, level: 0); if previous < 0 { view.beginAppearance() } }
            guard current == .recording else { return }
            meterCarry += dt
            while meterCarry >= 0.045 {
                meterCarry -= 0.045
                let t = CGFloat(cycle)
                let syllable = abs(sin(t * 7.6)) * (0.55 + 0.45 * sin(t * 1.9 + 0.6))
                let pause = t > 1.45 && t < 1.75 ? 0.08 : 1
                view.push(level: min(1, max(0, (0.12 + 0.82 * syllable) * CGFloat(pause) + noise.range(-0.06, 0.06))))
            }
        }
    }
}
