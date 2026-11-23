import AppKit
import Network

/// Everything the Studio shows, read fresh from the app each refresh.
struct StudioSnapshot {
    var version = ""
    var hotKeyChoices = [String]()
    var hotKeyIndex = 0
    var hotKeyGlyph = "⌥"
    var hotKeyCaption = "Option ขวา"
    var hotKeyRunning = false
    var permissions = [(name: String, granted: Bool, panel: String)]()
    var endpoint = ""
    var language = LanguageMode.thaiMix
    var allowPaste = false
    var reviewOnline = false
    var reviewSummary = ""
    var connectionTitle = ""
    var chatGPTAccount: String?
    var usesChatGPT = true
    var localAI = LocalAIService.State.unknown
    var openAtLogin = false
    var quickFixChordIndex = 0
    var writingNote = ""
    var dictionaryCount = 0
    var lastText = ""
}

/// Commands the Studio sends back to the app. Existing dialogs stay the source of truth.
struct StudioActions {
    var snapshot: () -> StudioSnapshot
    var setHotKey: (Int) -> Void
    var setLanguage: (LanguageMode) -> Void
    var setPaste: (Bool) -> Void
    var editEndpoint: () -> Void
    var configureReview: () -> Void
    var editGuidance: () -> Void
    var openDictionary: () -> Void
    var teachLast: () -> Void
    var showResults: () -> Void
    var showSolUsage: () -> Void
    var previewEffect: () -> Void
    var copyLast: () -> Void
    var requestPermission: (String) -> Void
    var signInChatGPT: () -> Void
    var signOutChatGPT: () -> Void
    var startLocalAI: () -> Void
    var setOpenAtLogin: (Bool) -> Bool
    var quickFix: () -> Void
    var setQuickFixChord: (Int) -> Void
}

enum PinkStudio {
    private static var controller: StudioWindowController?

    static func show(_ actions: StudioActions) {
        let current = controller ?? StudioWindowController(actions: actions)
        controller = current
        current.refresh()
        NSApp.activate(ignoringOtherApps: true)
        current.showWindow(nil)
        current.window?.makeKeyAndOrderFront(nil)
    }

    static func refreshIfVisible() {
        guard let controller, controller.window?.isVisible == true else { return }
        controller.refresh()
    }

    /// Visual QA: renders the Studio offscreen to a PNG without touching permissions.
    static func render(_ actions: StudioActions, to url: URL) throws {
        // Images for the website never show the signed-in account.
        var clean = actions
        clean.snapshot = { var value = actions.snapshot(); value.chatGPTAccount = nil; value.usesChatGPT = true; return value }
        let controller = StudioWindowController(actions: clean)
        controller.refresh()
        try controller.snapshotPNG(to: url)
    }
}

private final class FlippedStack: NSView { override var isFlipped: Bool { true } }

final class StudioWindowController: NSWindowController, NSWindowDelegate {
    private let actions: StudioActions
    private var snapshot = StudioSnapshot()
    private let showcase = PinkVoiceHUDView(frame: NSRect(x: 0, y: 0, width: 456, height: 149))
    private let keycap = KeycapView(frame: .zero)
    private let readyPill = StatusPill(frame: .zero)
    private let modePill = StatusPill(frame: .zero)
    private let hotKeyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languageControl = NSSegmentedControl(labels: ["ไทยปนอังกฤษ", "ไทยล้วน"], trackingMode: .selectOne, target: nil, action: nil)
    private let pasteSwitch = NSSwitch()
    private let loginSwitch = NSSwitch()
    private let chordPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let quickFixDetail = StudioText.wrapping("", PinkTheme.rounded(11.5, .medium), PinkTheme.textSecondary, width: 170)
    private let endpointLabel = StudioText.label("", PinkTheme.mono(11.5), PinkTheme.textSecondary)
    private let reviewLabel = StudioText.label("", PinkTheme.rounded(11.5, .medium), PinkTheme.textSecondary)
    private let accountLabel = StudioText.label("", PinkTheme.rounded(11.5, .medium), PinkTheme.textSecondary)
    private lazy var signInButton = PinkButton("Sign in with ChatGPT", style: .primary, symbol: "person.crop.circle.badge.checkmark") { [weak self] in self?.actions.signInChatGPT() }
    private lazy var signOutButton = PinkButton("ออกจากระบบ") { [weak self] in self?.run(self?.actions.signOutChatGPT) }
    private let noteLabel = StudioText.label("", PinkTheme.rounded(11.5, .medium), PinkTheme.textSecondary)
    private let dictionaryLabel = StudioText.label("", PinkTheme.rounded(11.5, .medium), PinkTheme.textSecondary)
    private let lastTextLabel = StudioText.wrapping("", PinkTheme.rounded(17, .semibold), .white, width: 380)
    private let serverPill = StatusPill(frame: .zero)
    private var tileValues = [String: (NSTextField, StatusPill)]()
    private var permissionRows = [(StatusPill, PinkButton)]()
    private var keycapTimer: Timer?
    private var serverReachable: Bool?
    private var probe: NWConnection?

    init(actions: StudioActions) {
        self.actions = actions
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "\(Brand.name) Studio"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 940, height: 640)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = PinkTheme.ink
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("code-only") }

    // MARK: Layout

    private func build() {
        guard let window else { return }
        let backdrop = StudioBackdrop()
        window.contentView = backdrop
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: backdrop.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor)
        ])
        let document = FlippedStack()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.contentView.drawsBackground = false

        var sections: [NSView] = [hero(), tiles(), columns([speakingSection(), accuracySection()]),
                                  columns([permissionSection(), lastTextCard()])]
        if let family = familySection() { sections.append(family) }
        sections.append(footer())
        let page = NSStackView(views: sections)
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 22
        page.setCustomSpacing(30, after: page.arrangedSubviews[1])
        page.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(page)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            page.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 34),
            page.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -34),
            page.topAnchor.constraint(equalTo: document.topAnchor, constant: 46),
            page.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -30)
        ])
        for view in page.arrangedSubviews { view.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
    }

    private func hero() -> NSView {
        let surface = StudioSurface()
        surface.cornerRadius = 26
        surface.tint = PinkTheme.plumHigh
        surface.emphasis = 0.6
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.heightAnchor.constraint(equalToConstant: 262).isActive = true

        let title = GradientTitle(text: "\(Brand.name)", size: 46)
        let subtitle = StudioText.wrapping("กดปุ่มค้างแล้วพูดไทยปนอังกฤษ ปล่อยปุ่มเมื่อพูดจบ ข้อความจะไปอยู่ในช่องพิมพ์ที่เลือกไว้",
                                           PinkTheme.rounded(14, .medium), PinkTheme.textSecondary, width: 360)
        let pills = NSStackView(views: [readyPill, modePill])
        pills.spacing = 8
        let tryButton = PinkButton("ลองเอฟเฟกต์บนจอ", symbol: "sparkles") { [weak self] in self?.actions.previewEffect() }
        let copyButton = PinkButton("คัดลอกข้อความล่าสุด", symbol: "doc.on.doc") { [weak self] in self?.actions.copyLast() }
        var heroButtons: [NSView] = [tryButton, copyButton]
        if TutorialWindow.isAvailable {
            let tutorial = PinkButton("ดูวิธีใช้ 40 วิ", style: .primary, symbol: "play.fill") { TutorialWindow.show() }
            tutorial.big = true
            tutorial.setAccessibilityLabel("ดูวิดีโอวิธีใช้")
            heroButtons.insert(tutorial, at: 0)
        }
        let buttons = NSStackView(views: heroButtons)
        buttons.alignment = .centerY
        buttons.spacing = 10
        let left = NSStackView(views: [StudioText.eyebrow("Studio · พูดแทนพิมพ์"), title, subtitle, pills, buttons])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 10
        left.setCustomSpacing(2, after: left.arrangedSubviews[0])
        left.setCustomSpacing(16, after: pills)

        showcase.showcase = true
        showcase.translatesAutoresizingMaskIntoConstraints = false
        keycap.translatesAutoresizingMaskIntoConstraints = false
        let stageLabel = StudioText.label("ตัวอย่างแถบตอนพูดจริง", PinkTheme.rounded(11, .semibold), PinkTheme.textMuted)
        let right = NSView()
        right.translatesAutoresizingMaskIntoConstraints = false
        for view in [showcase, keycap, stageLabel] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; right.addSubview(view) }
        NSLayoutConstraint.activate([
            showcase.widthAnchor.constraint(equalToConstant: 456), showcase.heightAnchor.constraint(equalToConstant: 149),
            showcase.trailingAnchor.constraint(equalTo: right.trailingAnchor), showcase.topAnchor.constraint(equalTo: right.topAnchor, constant: 4),
            keycap.widthAnchor.constraint(equalToConstant: 92), keycap.heightAnchor.constraint(equalToConstant: 74),
            keycap.centerXAnchor.constraint(equalTo: showcase.centerXAnchor), keycap.topAnchor.constraint(equalTo: showcase.bottomAnchor, constant: -4),
            stageLabel.centerXAnchor.constraint(equalTo: keycap.centerXAnchor), stageLabel.topAnchor.constraint(equalTo: keycap.bottomAnchor, constant: 2),
            right.widthAnchor.constraint(equalToConstant: 456)
        ])

        for view in [left, right] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(view) }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 34),
            left.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
            right.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
            right.topAnchor.constraint(equalTo: surface.topAnchor, constant: 10),
            right.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -10)
        ])
        return surface
    }

    private func tiles() -> NSView {
        let specs: [(String, String, String, () -> Void)] = [
            ("hotkey", "keyboard", "ปุ่มลัด", { [weak self] in self?.requestFirstMissingPermission() }),
            ("server", "cpu", "Local AI ในเครื่อง", { [weak self] in self?.actions.startLocalAI(); self?.probeServer() }),
            ("review", "wand.and.stars", "ตรวจคำ", { [weak self] in self?.run(self?.actions.configureReview) }),
            ("words", "character.book.closed", "คลังคำของฉัน", { [weak self] in self?.run(self?.actions.openDictionary) })
        ]
        let row = NSStackView(views: specs.map { key, symbol, caption, action in tile(key: key, symbol: symbol, caption: caption, action: action) })
        row.distribution = .fillEqually
        row.spacing = 14
        return row
    }

    private func tile(key: String, symbol: String, caption: String, action: @escaping () -> Void) -> NSView {
        let surface = ClickSurface(action: action)
        surface.hoverable = true
        surface.cornerRadius = 18
        surface.setAccessibilityLabel(caption)
        let icon = IconBadge(symbol: symbol)
        let captionLabel = StudioText.label(caption, PinkTheme.rounded(11.5, .semibold), PinkTheme.textMuted)
        let value = StudioText.label("—", PinkTheme.rounded(15, .bold))
        let pill = StatusPill(frame: .zero)
        let text = NSStackView(views: [captionLabel, value, pill])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let stack = NSStackView(views: [icon, text])
        stack.alignment = .top
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -16)
        ])
        tileValues[key] = (value, pill)
        return surface
    }

    private func columns(_ views: [NSView]) -> NSView {
        let row = NSStackView(views: views)
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = 18
        return row
    }

    private func section(_ eyebrow: String, _ title: String, rows: [NSView]) -> NSView {
        let surface = StudioSurface()
        surface.cornerRadius = 20
        var items: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { items.append(Hairline()) }
            items.append(row)
        }
        let list = NSStackView(views: items)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        list.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 18),
            list.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -18),
            list.topAnchor.constraint(equalTo: surface.topAnchor, constant: 16),
            list.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -16)
        ])
        for item in items { item.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        let heading = StudioText.label(title, PinkTheme.rounded(20, .heavy))
        let stack = NSStackView(views: [StudioText.eyebrow(eyebrow), heading, surface])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(12, after: heading)
        surface.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func row(_ symbol: String, _ title: String, detail: NSView, accessory: NSView) -> NSView {
        let icon = IconBadge(symbol: symbol, size: 30)
        let titleLabel = StudioText.label(title, PinkTheme.rounded(13.5, .bold))
        let text = NSStackView(views: [titleLabel, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, text, NSView(), accessory])
        row.alignment = .centerY
        row.spacing = 12
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func detail(_ text: String) -> NSTextField {
        StudioText.wrapping(text, PinkTheme.rounded(11.5, .medium), PinkTheme.textSecondary, width: 230)
    }

    private func speakingSection() -> NSView {
        hotKeyPopup.target = self
        hotKeyPopup.action = #selector(hotKeyChanged)
        languageControl.target = self
        languageControl.action = #selector(languageChanged)
        pasteSwitch.target = self
        pasteSwitch.action = #selector(pasteChanged)
        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged)
        return section("Speaking", "การพูดและใส่ข้อความ", rows: [
            row("hand.point.up.left.fill", "ปุ่มกดค้างเพื่อพูด", detail: detail("กดค้างระหว่างพูด ปล่อยเมื่อจบประโยค"), accessory: hotKeyPopup),
            row("globe.asia.australia.fill", "ภาษา", detail: detail("ไทยปนอังกฤษเหมาะกับชื่อแบรนด์และศัพท์งาน"), accessory: languageControl),
            row("power", "เปิดพร้อม Mac", detail: detail("เปิด \(Brand.name) และ Local AI ให้เองเมื่อเข้าเครื่อง"), accessory: loginSwitch),
            row("doc.on.clipboard.fill", "วางด้วย ⌘V", detail: detail("ใช้กับแอปที่พิมพ์ตรงไม่ขึ้น ข้อความจะแทนที่คลิปบอร์ด"), accessory: pasteSwitch),
            row("server.rack", "Local AI บน Mac", detail: endpointLabel,
                accessory: PinkButton("แก้ไข") { [weak self] in self?.run(self?.actions.editEndpoint) })
        ])
    }

    private func accuracySection() -> NSView {
        let account = NSStackView(views: [signInButton, signOutButton])
        account.spacing = 8
        return section("Accuracy", "ความแม่นยำของคำ", rows: [
            row("wand.and.stars", "โหมดถอดและตรวจคำ", detail: reviewLabel,
                accessory: PinkButton("ปรับโหมด") { [weak self] in self?.run(self?.actions.configureReview) }),
            row("person.fill", "บัญชี ChatGPT", detail: accountLabel, accessory: account),
            row("bolt.fill", "แก้คำด่วน", detail: quickFixDetail, accessory: quickFixControls()),
            row("text.quote", "คำแนะนำการถอด", detail: noteLabel,
                accessory: PinkButton("เขียน") { [weak self] in self?.run(self?.actions.editGuidance) }),
            row("character.book.closed.fill", "คำและแบรนด์ของฉัน", detail: dictionaryLabel,
                accessory: PinkButton("เปิดคลังคำ", style: .primary) { [weak self] in self?.run(self?.actions.openDictionary) }),
            row("graduationcap.fill", "สอนคำจากครั้งล่าสุด", detail: detail("เลือกคำที่ฟังผิดจากประโยคล่าสุดแล้วสอนให้จำ"),
                accessory: PinkButton("สอนคำ") { [weak self] in self?.run(self?.actions.teachLast) }),
            row("checklist", "ผลตรวจคำล่าสุด", detail: detail("ดูคำที่ระบบไม่แน่ใจจากครั้งล่าสุด"),
                accessory: PinkButton("ดูผล") { [weak self] in self?.run(self?.actions.showResults) })
        ])
    }

    private func quickFixControls() -> NSView {
        chordPopup.removeAllItems()
        chordPopup.addItems(withTitles: QuickFixChord.allCases.map(\.menuTitle))
        chordPopup.target = self
        chordPopup.action = #selector(chordChanged)
        chordPopup.setAccessibilityLabel("ปุ่มลัดแก้คำ")
        return chordPopup
    }

    @objc private func chordChanged() { actions.setQuickFixChord(chordPopup.indexOfSelectedItem); refresh() }

    private func permissionSection() -> NSView {
        let names: [(String, String, String)] = [
            ("keyboard.badge.ellipsis", "Input Monitoring", "ให้แอปรู้ว่ากดปุ่มลัดค้างอยู่"),
            ("accessibility", "Accessibility", "ใส่ข้อความลงช่องพิมพ์ที่เลือก"),
            ("mic.fill", "ไมโครโฟน", "ฟังเสียงเฉพาะตอนกดปุ่มค้าง")
        ]
        var rows: [NSView] = names.enumerated().map { index, item in
            let pill = StatusPill(frame: .zero)
            let button = PinkButton("อนุญาต", style: .primary) { [weak self] in self?.requestPermission(at: index) }
            let accessory = NSStackView(views: [pill, button])
            accessory.spacing = 8
            permissionRows.append((pill, button))
            return row(item.0, item.1, detail: detail(item.2), accessory: accessory)
        }
        rows.append(row("chart.line.uptrend.xyaxis", "ค่าใช้จ่าย Sol", detail: detail("โทเคนและค่าประมาณเป็นเงินบาทของการตรวจออนไลน์"),
                        accessory: PinkButton("เปิดรายงาน") { [weak self] in self?.run(self?.actions.showSolUsage) }))
        return section("Access", "สิทธิ์และค่าใช้จ่าย", rows: rows)
    }

    private func lastTextCard() -> NSView {
        let surface = StudioSurface()
        surface.cornerRadius = 20
        surface.tint = PinkTheme.rgb(0x3B1A44)
        surface.emphasis = 0.35
        let quote = StudioText.label("“", NSFont.systemFont(ofSize: 64, weight: .black), PinkTheme.hotPink.withAlphaComponent(0.75))
        let copy = PinkButton("คัดลอก", style: .primary, symbol: "doc.on.doc") { [weak self] in self?.actions.copyLast() }
        let teach = PinkButton("สอนคำจากประโยคนี้") { [weak self] in self?.run(self?.actions.teachLast) }
        let buttons = NSStackView(views: [copy, teach])
        buttons.spacing = 10
        let stack = NSStackView(views: [quote, lastTextLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(-26, after: quote)
        stack.setCustomSpacing(16, after: lastTextLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -20)
        ])
        let heading = StudioText.label("ประโยคที่พูดล่าสุด", PinkTheme.rounded(20, .heavy))
        let outer = NSStackView(views: [StudioText.eyebrow("Last take"), heading, surface])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 4
        outer.setCustomSpacing(12, after: heading)
        surface.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        return outer
    }

    /// Sister apps from Info.plist (PVFamily); absent in a plain open-source build.
    private func familySection() -> NSView? {
        guard !Brand.family.isEmpty else { return nil }
        let cards = Brand.family.map { app -> NSView in
            let card = ClickSurface { NSWorkspace.shared.open(app.url) }
            card.hoverable = true
            card.cornerRadius = 20
            card.tint = PinkTheme.rgb(0x3B1A44)
            card.setAccessibilityLabel("\(app.name) \(app.tagline)")
            let name = StudioText.label(app.name, PinkTheme.rounded(18, .heavy))
            let tagline = StudioText.wrapping(app.tagline, PinkTheme.rounded(12, .medium), PinkTheme.textSecondary, width: 300)
            let more = StudioText.label("ดูเพิ่ม →", PinkTheme.rounded(12, .bold), PinkTheme.hotPink)
            let text = NSStackView(views: [name, tagline, more])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 4
            let row = NSStackView(views: [IconBadge(symbol: app.symbol, size: 46), text])
            row.alignment = .top
            row.spacing = 14
            row.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
                row.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -18),
                row.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
                row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18)
            ])
            return card
        }
        let row = NSStackView(views: cards)
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = 18
        let heading = StudioText.label("ครอบครัว Pink", PinkTheme.rounded(20, .heavy))
        let stack = NSStackView(views: [StudioText.eyebrow("More from pngoung"), heading, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(12, after: heading)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func footer() -> NSView {
        let label = StudioText.label("", PinkTheme.rounded(11, .medium), PinkTheme.textMuted)
        label.tag = 901
        var views: [NSView] = [label]
        if let line = PinkTheme.credit(size: 12.5) {
            let credit = NSTextField(labelWithAttributedString: line)
            credit.setAccessibilityLabel(line.string.replacingOccurrences(of: "♥", with: "love"))
            views.insert(credit, at: 0)
        }
        if let source = Brand.sourceURL {
            views.append(PinkButton("ดูซอร์สโค้ด", symbol: "chevron.left.forwardslash.chevron.right") { NSWorkspace.shared.open(source) })
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        return stack
    }

    // MARK: Refresh

    func refresh() {
        snapshot = actions.snapshot()
        let ready = snapshot.hotKeyRunning && snapshot.permissions.allSatisfy(\.granted)
        readyPill.text = ready ? "พร้อมฟัง" : "ต้องเปิดสิทธิ์"
        readyPill.color = ready ? PinkTheme.mint : PinkTheme.amber
        modePill.text = snapshot.reviewOnline ? "ตรวจคำออนไลน์" : "ในเครื่องเท่านั้น"
        modePill.color = snapshot.reviewOnline ? PinkTheme.rose : PinkTheme.violet
        keycap.glyph = snapshot.hotKeyGlyph
        keycap.caption = snapshot.hotKeyCaption

        if hotKeyPopup.numberOfItems != snapshot.hotKeyChoices.count {
            hotKeyPopup.removeAllItems()
            hotKeyPopup.addItems(withTitles: snapshot.hotKeyChoices)
        }
        hotKeyPopup.selectItem(at: snapshot.hotKeyIndex)
        languageControl.selectedSegment = snapshot.language == .thaiMix ? 0 : 1
        pasteSwitch.state = snapshot.allowPaste ? .on : .off
        loginSwitch.state = snapshot.openAtLogin ? .on : .off
        chordPopup.selectItem(at: snapshot.quickFixChordIndex)
        let chord = QuickFixChord.allCases[min(snapshot.quickFixChordIndex, QuickFixChord.allCases.count - 1)]
        quickFixDetail.stringValue = chord == .off
            ? "ปิดปุ่มลัดไว้ ยังเปิดจากเมนูได้"
            : "ไฮไลต์คำผิด แล้วกดสองปุ่มนี้พร้อมกัน กดอีกครั้งเพื่อปิด"
        endpointLabel.stringValue = snapshot.endpoint
        reviewLabel.stringValue = snapshot.reviewSummary
        accountLabel.stringValue = snapshot.chatGPTAccount.map { "ล็อกอินแล้ว · \($0)" }
            ?? (snapshot.usesChatGPT ? "ยังไม่ได้ล็อกอิน ใช้โควตาแพ็กเกจ ChatGPT แทน API key" : "ตอนนี้ใช้ \(snapshot.connectionTitle)")
        signInButton.isHidden = snapshot.chatGPTAccount != nil
        signOutButton.isHidden = snapshot.chatGPTAccount == nil
        noteLabel.stringValue = snapshot.writingNote.isEmpty ? "ยังไม่ได้เขียน ใช้กติกากลางของแอป" : snapshot.writingNote
        dictionaryLabel.stringValue = "สอนไว้ \(snapshot.dictionaryCount) คำ ใช้ทั้งในเครื่องและออนไลน์"
        lastTextLabel.stringValue = snapshot.lastText.isEmpty ? "ยังไม่มีประโยคในรอบนี้ ลองกดปุ่มค้างแล้วพูดดูค่ะ" : snapshot.lastText
        lastTextLabel.textColor = snapshot.lastText.isEmpty ? PinkTheme.textSecondary : .white

        setTile("hotkey", snapshot.hotKeyCaption, snapshot.hotKeyRunning ? ("พร้อม", PinkTheme.mint) : ("รออนุญาต", PinkTheme.amber))
        let granted = snapshot.permissions.filter(\.granted).count
        if snapshot.localAI == .ready { serverReachable = true }
        if snapshot.localAI == .starting {
            setTile("server", "กำลังเปิด", ("อุ่นเครื่องสักครู่", PinkTheme.violet))
        } else if snapshot.localAI == .missingRuntime {
            setTile("server", "ยังไม่ติดตั้ง", ("กดเพื่อติดตั้ง", PinkTheme.coral))
        } else if let reachable = serverReachable {
            setTile("server", reachable ? "ทำงานอยู่" : "ไม่ตอบ", reachable ? ("พร้อมถอด", PinkTheme.mint) : ("กดเพื่อเปิด", PinkTheme.coral))
        } else {
            setTile("server", "กำลังตรวจ", ("รอสักครู่", PinkTheme.violet))
        }
        setTile("review", snapshot.reviewOnline ? "Local AI + ออนไลน์" : "Local AI", snapshot.reviewOnline ? ("ตรวจทานก่อนใส่", PinkTheme.rose) : ("ในเครื่อง", PinkTheme.violet))
        setTile("words", "\(snapshot.dictionaryCount) คำ", ("สิทธิ์ \(granted)/\(snapshot.permissions.count)", granted == snapshot.permissions.count ? PinkTheme.mint : PinkTheme.amber))

        for (index, row) in permissionRows.enumerated() where snapshot.permissions.indices.contains(index) {
            let granted = snapshot.permissions[index].granted
            row.0.text = granted ? "พร้อม" : "รออนุญาต"
            row.0.color = granted ? PinkTheme.mint : PinkTheme.amber
            row.1.isHidden = granted
        }
        if let footer = window?.contentView?.viewWithTag(901) as? NSTextField {
            footer.stringValue = "\(Brand.name) \(snapshot.version)  ·  เสียงถอดบน Mac เครื่องนี้ด้วย Local AI  ·  โหมดออนไลน์ส่งเฉพาะข้อความที่ถอดแล้ว"
        }
    }

    private func setTile(_ key: String, _ value: String, _ status: (String, NSColor)) {
        guard let tile = tileValues[key] else { return }
        tile.0.stringValue = value
        tile.1.text = status.0
        tile.1.color = status.1
    }

    // MARK: Actions

    private func run(_ action: (() -> Void)?) {
        action?()
        refresh()
    }

    @objc private func hotKeyChanged() { actions.setHotKey(hotKeyPopup.indexOfSelectedItem); refresh() }
    @objc private func languageChanged() { actions.setLanguage(languageControl.selectedSegment == 0 ? .thaiMix : .thai); refresh() }
    @objc private func pasteChanged() { actions.setPaste(pasteSwitch.state == .on); refresh() }
    @objc private func loginChanged() {
        if !actions.setOpenAtLogin(loginSwitch.state == .on) {
            let alert = NSAlert()
            alert.messageText = "ตั้งให้เปิดพร้อม Mac ไม่สำเร็จ"
            alert.informativeText = "เปิด System Settings › General › Login Items แล้วเพิ่ม \(Brand.name) เองได้"
            alert.runModal()
        }
        refresh()
    }

    private func requestPermission(at index: Int) {
        guard snapshot.permissions.indices.contains(index) else { return }
        actions.requestPermission(snapshot.permissions[index].panel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
    }

    private func requestFirstMissingPermission() {
        if let index = snapshot.permissions.firstIndex(where: { !$0.granted }) { requestPermission(at: index) }
    }

    /// One TCP connection attempt to the configured loopback endpoint; no data is sent.
    private func probeServer() {
        probe?.cancel()
        serverReachable = nil
        refresh()
        guard let url = URL(string: snapshot.endpoint), let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (url.scheme == "wss" ? 443 : 80))) else {
            serverReachable = false; refresh(); return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        probe = connection
        var settled = false
        let settle: (Bool) -> Void = { [weak self, weak connection] reachable in
            DispatchQueue.main.async {
                guard !settled else { return }
                settled = true
                connection?.cancel()
                self?.serverReachable = reachable
                self?.refresh()
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: settle(true)
            case .failed, .waiting: settle(false)
            default: break
            }
        }
        connection.start(queue: .global(qos: .utility))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settle(false) }
    }

    // MARK: Window lifecycle

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        probeServer()
        keycapTimer?.invalidate()
        var ticks = 0
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.keycap.pressed = self.showcase.state == .recording
            ticks += 1
            if ticks % 30 == 0 { self.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        keycapTimer = timer
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }
    func windowWillClose(_ notification: Notification) {
        keycapTimer?.invalidate()
        keycapTimer = nil
        probe?.cancel()
    }

    func snapshotPNG(to url: URL) throws {
        guard let window, let content = window.contentView else { return }
        window.setFrame(NSRect(x: 0, y: 0, width: 980, height: 1700), display: false)
        content.layoutSubtreeIfNeeded()
        serverReachable = true
        refresh()
        showcase.settle(for: 1.6)
        keycap.pressed = true
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

// MARK: Small views

private final class ClickSurface: StudioSurface {
    private let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("code-only") }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}

private final class IconBadge: NSView {
    private let symbol: String
    private let size: CGFloat
    init(symbol: String, size: CGFloat = 38) {
        self.symbol = symbol
        self.size = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("code-only") }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = CGPath(roundedRect: rect, cornerWidth: rect.height * 0.32, cornerHeight: rect.height * 0.32, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let fill = PinkTheme.gradient([(PinkTheme.hotPink.withAlphaComponent(0.55), 0), (PinkTheme.violet.withAlphaComponent(0.45), 1)]) {
            context.drawLinearGradient(fill, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: rect.maxX, y: 0), options: [])
        }
        context.restoreGState()
        context.addPath(path)
        context.setStrokeColor(PinkTheme.blush.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))) else { return }
        let box = image.size
        image.draw(in: NSRect(x: bounds.midX - box.width / 2, y: bounds.midY - box.height / 2, width: box.width, height: box.height))
    }
}

private final class Hairline: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("code-only") }
    override func draw(_ dirtyRect: NSRect) {
        PinkTheme.rose.withAlphaComponent(0.12).setFill()
        bounds.fill()
    }
}

/// Large display title filled with the brand gradient.
private final class GradientTitle: NSView {
    private let text: NSAttributedString
    init(text: String, size: CGFloat) {
        self.text = NSAttributedString(string: text, attributes: [.font: PinkTheme.rounded(size, .black), .foregroundColor: NSColor.white, .kern: -0.8])
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { fatalError("code-only") }
    override var intrinsicContentSize: NSSize { let s = text.size(); return NSSize(width: ceil(s.width) + 4, height: ceil(s.height) + 2) }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // A grayscale bitmap where white marks the glyphs; Quartz clips the gradient to it.
        let scale: CGFloat = 2
        guard bounds.width > 0, bounds.height > 0,
              let gray = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        gray.setFillColor(gray: 0, alpha: 1)
        gray.fill(CGRect(x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale))
        gray.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: gray, flipped: false)
        text.draw(at: NSPoint(x: 1, y: 1))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgMask = gray.makeImage() else { return }
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 18, color: PinkTheme.hotPink.withAlphaComponent(0.55).cgColor)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.clip(to: bounds, mask: cgMask)
        if let gradient = PinkTheme.gradient([(PinkTheme.blush, 0), (PinkTheme.rose, 0.35), (PinkTheme.hotPink, 0.7), (PinkTheme.peach, 1)]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: bounds.maxY), end: CGPoint(x: bounds.maxX, y: 0), options: [])
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
