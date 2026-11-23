import Cocoa
import ApplicationServices
import AVFoundation

@main final class AppDelegate: NSObject, NSApplicationDelegate, HotKeyDelegate, LiveASRDelegate {
    static func main() {
        if CommandLine.arguments.contains("--access-status") {
            let settings = Settings()
            let microphone = AVCaptureDevice.authorizationStatus(for: .audio).rawValue
            print("mic=\(microphone) ax=\(AXIsProcessTrusted()) input=\(CGPreflightListenEventAccess()) hotKey=\(settings.hotKey.rawValue)")
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // A normal Dock app; render-only runs stay out of the Dock.
        let renderOnly = CommandLine.arguments.contains { $0.hasSuffix("-render") || $0 == "--hud-movie" }
        application.setActivationPolicy(renderOnly ? .accessory : .regular)
        withExtendedLifetime(delegate) { application.run() }
    }

    private let wordReview = WordReviewController()
    private weak var appPasteModeItem: NSMenuItem?
    private var assessments = [DictationAssessment?]()
    private var lastHeard = ""
    private let settings = Settings(); private let hotKey = EventTap(); private let hud = PinkVoiceHUD(); private var statusItem: NSStatusItem!
    private var streamer: AudioStreamer?; private var session: UUID?; private var target: FocusSnapshot?; private var finals = [String](); private var didInsert = false
    private var isHolding = false; private var wasCancelled = false; private var timer: Timer?; private var lastText = ""
    private let slowResponseInterval: TimeInterval = 8
    private let responseTimeout: TimeInterval = 24
    private var releaseUptime: TimeInterval?
    private var handoverInProgress = false
    private let reviewDelivery = FinalReviewDelivery()
    private var capturedReview: FinalReviewConfiguration?
    private var destinationLeft = false
    private var usedLocalFallback = false
    private var voice = VoiceActivity()
    private var silenceTimer: Timer?

    func applicationWillFinishLaunching(_ notification: Notification) { _ = launchedAsLoginItem }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        EditingMenu.install()
        wordReview.onSettingsChanged = { [weak self] in self?.reviewSettingsChanged(); PinkStudio.refreshIfVisible() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activatedApplication(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if let appMenu = NSApp.mainMenu?.items.first?.submenu {
            let studio = NSMenuItem(title: "เปิด \(Brand.name) Studio…", action: #selector(openStudio), keyEquivalent: ",")
            studio.target = self
            let about = NSMenuItem(title: "เกี่ยวกับ \(Brand.name)", action: #selector(showAbout), keyEquivalent: "")
            about.target = self
            appMenu.insertItem(about, at: 0)
            appMenu.insertItem(studio, at: 1)
            appMenu.insertItem(.separator(), at: 2)
            wordReview.addItems(to: appMenu, displayScore: false)
            addSolUsage(to: appMenu)
            appPasteModeItem = addPasteMode(to: appMenu)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙︎ \(Brand.name)"
        rebuildMenu()
        if let fixImage = argumentURL("--quickfix-render") {
            do { try QuickFixPanel.render(to: fixImage) } catch { fputs("Quick fix render failed: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
            return
        }
        if let installImage = argumentURL("--installer-render") {
            do { try LocalAIInstallWindow.render(to: installImage) } catch { fputs("Installer render failed: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
            return
        }
        if let studioImage = argumentURL("--studio-render") {
            lastText = "วันนี้เราจะส่งบรีฟให้ทีม Pink Cuts กับ molto ก่อนบ่ายสองโมงครับ"
            do { try PinkStudio.render(studioActions(), to: studioImage) } catch { fputs("Pink voices Studio render failed: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
            return
        }
        if let movieDirectory = argumentURL("--hud-movie") {
            do { try PinkVoiceHUD.renderMovieFrames(to: movieDirectory) } catch { fputs("Pink voices HUD movie failed: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
            return
        }
        if let renderDirectory = renderDirectory() {
            do { try PinkVoiceHUD.renderPreviews(to: renderDirectory) } catch { fputs("Pink voices HUD render failed: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
            return
        }
        hotKey.delegate = self; hotKey.key = settings.hotKey; hotKey.chord = settings.quickFixChord; QuickFix.chord = settings.quickFixChord
        activateHotKeyWhenReady()
        NotificationCenter.default.addObserver(forName: LocalAIService.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.localAIStateChanged()
        }
        Task { @MainActor in
            await LocalAIService.ensureRunning()
            // First launch on a new Mac: offer the one-time Local AI setup.
            if LocalAIService.state == .missingRuntime { LocalAIInstallWindow.show { PinkStudio.refreshIfVisible() } }
        }
        // Opened by the person (Finder, Dock, Spotlight): show Studio. Opened at login: stay quiet.
        if !launchedAsLoginItem && !CommandLine.arguments.contains("--hud-preview") && !CommandLine.arguments.contains("--fixture") {
            DispatchQueue.main.async { [weak self] in self?.openStudio() }
        }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio).rawValue
        Telemetry.shared.record(UUID(), "startup", "mic=\(mic) ax=\(AXIsProcessTrusted()) input=\(CGPreflightListenEventAccess()) tap=\(hotKey.isRunning) key=\(settings.hotKey.rawValue)")
        if CommandLine.arguments.contains("--fixture") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.fixture() } }
        if CommandLine.arguments.contains("--hud-preview") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.previewVisual() } }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openStudio()
        return true
    }
    @objc private func openStudio() { PinkStudio.show(studioActions()) }
    @objc private func openTutorial() { TutorialWindow.show() }
    @objc private func showAbout() {
        let credits = NSMutableAttributedString(attributedString: PinkTheme.credit(size: 12) ?? NSAttributedString())
        if let source = Brand.sourceURL {
            credits.append(NSAttributedString(string: "\nSource: " + source.absoluteString, attributes: [.link: source, .font: NSFont.systemFont(ofSize: 11)]))
        }
        credits.append(NSAttributedString(string: "\nLocal AI: OpenThai 2.0 ASR by iApp (OpenMDW-1.1)", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private lazy var launchedAsLoginItem: Bool = {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }()

    /// ⌃⌥F: teach the highlighted word, and fix it in place when the field allows it.
    @objc private func quickFix() {
        guard !isHolding, streamer == nil else { return }
        QuickFix.grabSelection { [weak self] selection in
            guard let self else { return }
            let existing = self.settings.dictionaryRows.first { $0.alias.lowercased() == selection.text.lowercased() }?.spelling
            let isBrand = existing.map { self.settings.soundAlikeTerms.contains($0) } ?? true
            let canReplace = selection.target != nil && !selection.text.isEmpty
            QuickFixPanel.present(heard: selection.text, suggestion: existing, isBrand: isBrand, canReplace: canReplace,
                                  returnTo: selection.app) { [weak self] result in
                guard let self, self.settings.teach(heard: result.heard, written: result.written, soundAlike: result.soundAlike) else { return false }
                let written = result.written.trimmingCharacters(in: .whitespacesAndNewlines)
                let notice = UUID()
                Telemetry.shared.record(notice, "quick_fix_learned", result.soundAlike ? "sound_alike" : "exact")
                self.rebuildMenu()
                if result.replaceInPlace, let target = selection.target {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        let outcome = SafeInserter.insert(written, target: target, requireOriginalSelection: true)
                        Telemetry.shared.record(notice, "quick_fix_replace", outcome)
                    }
                }
                self.hud.show(.learned, session: notice)
                self.hud.finish(.learned, session: notice, hideAfter: 1.6)
                return true
            }
        }
    }

    private func localAIStateChanged() {
        guard !isHolding, streamer == nil else { return }
        switch LocalAIService.state {
        case .starting: setStatus("กำลังเปิด Local AI")
        case .ready: statusItem.button?.title = "🎙︎ \(Brand.name)"
        case .missingRuntime: setStatus("ยังไม่พบ Local AI")
        case .failed: setStatus("เปิด Local AI ไม่สำเร็จ")
        case .unknown: break
        }
        PinkStudio.refreshIfVisible()
    }

    private func studioActions() -> StudioActions {
        StudioActions(
            snapshot: { [weak self] in self?.studioSnapshot() ?? StudioSnapshot() },
            setHotKey: { [weak self] index in
                guard let self, HoldKey.allCases.indices.contains(index) else { return }
                self.settings.hotKey = HoldKey.allCases[index]
                self.hotKey.key = self.settings.hotKey
                self.rebuildMenu()
            },
            setLanguage: { [weak self] mode in self?.settings.language = mode; self?.rebuildMenu() },
            setPaste: { [weak self] allowed in
                guard let self else { return }
                self.settings.allowClipboardPaste = allowed
                self.appPasteModeItem?.state = allowed ? .on : .off
                self.rebuildMenu()
            },
            editEndpoint: { [weak self] in self?.configureServer() },
            configureReview: { [weak self] in self?.wordReview.configureReview() },
            editGuidance: { [weak self] in self?.wordReview.editGuidance() },
            openDictionary: { [weak self] in self?.editBrandDictionary() },
            teachLast: { [weak self] in self?.teachLastWord() },
            showResults: { [weak self] in self?.wordReview.showResults() },
            showSolUsage: { SolUsageWindow.show() },
            previewEffect: { [weak self] in self?.previewVisual() },
            copyLast: { [weak self] in self?.copyLast() },
            requestPermission: { [weak self] panel in
                self?.requestSystemPermission(named: panel)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(panel)") { NSWorkspace.shared.open(url) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.activateHotKeyWhenReady() }
            },
            signInChatGPT: { [weak self] in self?.wordReview.beginChatGPTSignIn { _ in PinkStudio.refreshIfVisible() } },
            signOutChatGPT: { [weak self] in self?.wordReview.signOutChatGPT() },
            startLocalAI: {
                if LocalAIService.runtime == nil { LocalAIInstallWindow.show { PinkStudio.refreshIfVisible() } }
                else { Task { @MainActor in await LocalAIService.ensureRunning() } }
            },
            setOpenAtLogin: { enabled in LoginItem.set(enabled) },
            quickFix: { [weak self] in self?.quickFix() },
            setQuickFixChord: { [weak self] index in
                guard let self, QuickFixChord.allCases.indices.contains(index) else { return }
                let chord = QuickFixChord.allCases[index]
                self.settings.quickFixChord = chord
                self.hotKey.chord = chord
                QuickFix.chord = chord
                self.rebuildMenu()
            })
    }

    private func studioSnapshot() -> StudioSnapshot {
        let review = wordReview.finalReviewConfiguration
        let words = settings.dictionaryText.components(separatedBy: .newlines).filter { (try? BrandDictionary.rows($0))?.isEmpty == false }.count
        let key = settings.hotKey
        return StudioSnapshot(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            hotKeyChoices: HoldKey.allCases.map(\.title),
            hotKeyIndex: HoldKey.allCases.firstIndex(of: key) ?? 0,
            hotKeyGlyph: key == .rightOption ? "⌥" : key.title,
            hotKeyCaption: key == .rightOption ? "Option ขวา" : "ปุ่ม \(key.title)",
            hotKeyRunning: hotKey.isRunning,
            permissions: [
                ("Input Monitoring", CGPreflightListenEventAccess(), "Privacy_ListenEvent"),
                ("Accessibility", AXIsProcessTrusted(), "Privacy_Accessibility"),
                ("ไมโครโฟน", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Privacy_Microphone")
            ],
            endpoint: settings.endpoint,
            language: settings.language,
            allowPaste: settings.allowClipboardPaste,
            reviewOnline: review.isOnline,
            reviewSummary: review.isOnline ? "ถอดด้วย Local AI · ตรวจด้วย \(review.model ?? "AI")" : "Local AI บน Mac อย่างเดียว ไม่ส่งข้อมูลออก",
            connectionTitle: review.keySource.title,
            chatGPTAccount: ChatGPTAccount.current()?.label,
            usesChatGPT: review.keySource == .chatGPT,
            localAI: LocalAIService.state,
            openAtLogin: LoginItem.isEnabled,
            quickFixChordIndex: QuickFixChord.allCases.firstIndex(of: settings.quickFixChord) ?? 0,
            writingNote: wordReview.writingNote,
            dictionaryCount: settings.dictionaryEnabled ? words : 0,
            lastText: lastText)
    }

    private func rebuildMenu() {
        let key = settings.hotKey.title
        let menu = NSMenu(); menu.addItem(withTitle: "\(Brand.name)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "เปิด \(Brand.name) Studio…", action: #selector(openStudio), keyEquivalent: ",")
        if TutorialWindow.isAvailable { menu.addItem(withTitle: "ดูวิธีใช้ 40 วิ…", action: #selector(openTutorial), keyEquivalent: "").target = self }
        menu.addItem(withTitle: "กด \(key) ค้างเพื่อพูด แล้วปล่อยเพื่อใส่ข้อความ", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: hotKey.isRunning ? "สถานะปุ่มลัด: พร้อม" : "สถานะปุ่มลัด: ต้องเปิด Input Monitoring", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator()); menu.addItem(withTitle: "คัดลอกข้อความล่าสุด", action: #selector(copyLast), keyEquivalent: "c")
        menu.addItem(withTitle: "ตั้งค่าปุ่มกดค้าง…", action: #selector(configureHoldKey), keyEquivalent: "")
        addPasteMode(to: menu)
        menu.addItem(withTitle: "ภาษา: " + settings.language.rawValue, action: #selector(toggleLanguage), keyEquivalent: "")
        menu.addItem(withTitle: "คำและแบรนด์ของฉัน…", action: #selector(editBrandDictionary), keyEquivalent: "")
        menu.addItem(withTitle: "สอนคำจากครั้งล่าสุด…", action: #selector(teachLastWord), keyEquivalent: "")
        let fixTitle = settings.quickFixChord == .off ? "แก้คำที่ไฮไลต์…" : "แก้คำที่ไฮไลต์… (กด \(settings.quickFixChord.words))"
        menu.addItem(withTitle: fixTitle, action: #selector(quickFix), keyEquivalent: "").target = self
        wordReview.addItems(to: menu)
        addSolUsage(to: menu)
        menu.addItem(withTitle: "เซิร์ฟเวอร์ในเครื่อง: " + settings.endpoint, action: #selector(configureServer), keyEquivalent: "")
        menu.addItem(withTitle: "สิทธิ์การใช้งาน…", action: #selector(showPermissions), keyEquivalent: "")
        menu.addItem(withTitle: "ดูตัวอย่างเอฟเฟกต์", action: #selector(previewVisual), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator()); menu.addItem(withTitle: "ออกจาก \(Brand.name)", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
        PinkStudio.refreshIfVisible()
    }
    private func addSolUsage(to menu: NSMenu) {
        menu.addItem(withTitle: "ค่าใช้จ่าย Sol…", action: #selector(showSolUsage), keyEquivalent: "").target = self
    }
    @objc private func showSolUsage() { SolUsageWindow.show() }
    @discardableResult private func addPasteMode(to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: "วางด้วย ⌘V (แทนที่คลิปบอร์ด)", action: #selector(toggleClipboardPaste), keyEquivalent: "")
        item.target = self
        item.state = settings.allowClipboardPaste ? .on : .off
        item.toolTip = "ใช้กับแอปที่รับการวางได้ดีกว่าการพิมพ์ คำถอดจะแทนที่สิ่งที่คัดลอกไว้"
        return item
    }
    @objc private func toggleClipboardPaste() {
        settings.allowClipboardPaste.toggle()
        appPasteModeItem?.state = settings.allowClipboardPaste ? .on : .off
        rebuildMenu()
    }
    @objc private func copyLast() { if !lastText.isEmpty { SafeInserter.copy(lastText); setStatus("คัดลอกแล้ว") } }
    @objc private func configureHoldKey() {
        let alert = NSAlert()
        alert.messageText = "ปุ่มกดค้างเพื่อพูด"
        alert.informativeText = "กด Option ขวาเพียงปุ่มเดียวค้างเพื่อพูด หรือเลือก F8/F7 หากต้องการใช้ปุ่มฟังก์ชัน"
        let choices = HoldKey.allCases
        let keys = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        keys.addItems(withTitles: choices.map(\.title))
        keys.selectItem(at: choices.firstIndex(of: settings.hotKey) ?? 0)
        alert.accessoryView = keys
        alert.addButton(withTitle: "บันทึก")
        alert.addButton(withTitle: "ยกเลิก")
        if alert.runModal() == .alertFirstButtonReturn, choices.indices.contains(keys.indexOfSelectedItem) {
            settings.hotKey = choices[keys.indexOfSelectedItem]
            hotKey.key = settings.hotKey
            rebuildMenu()
        }
    }
    @objc private func toggleLanguage() { settings.language = settings.language == .thaiMix ? .thai : .thaiMix; rebuildMenu() }
    @objc private func editBrandDictionary() { BrandDictionaryEditor.edit(settings, recentText: lastHeard) }
    @objc private func teachLastWord() { BrandDictionaryEditor.teach(settings, recentText: lastHeard) }
    @objc private func configureServer() {
        let alert = NSAlert(); alert.messageText = "Local AI ในเครื่อง"; alert.informativeText = "ใช้ได้เฉพาะ URL บนเครื่องนี้ ค่าเริ่มต้น ws://127.0.0.1:18081/v1/live"
        let field = NSTextField(string: settings.endpoint); field.frame.size.width = 390; alert.accessoryView = field; alert.addButton(withTitle: "บันทึก"); alert.addButton(withTitle: "ยกเลิก")
        if alert.runModal() == .alertFirstButtonReturn { settings.endpoint = field.stringValue; rebuildMenu() }
    }
    @objc private func showPermissions() {
        let panels = [
            ("Input Monitoring", CGPreflightListenEventAccess(), "Privacy_ListenEvent"),
            ("Accessibility", AXIsProcessTrusted(), "Privacy_Accessibility"),
            ("ไมโครโฟน", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Privacy_Microphone")
        ]
        let alert = NSAlert()
        alert.messageText = "สิทธิ์การใช้งาน \(Brand.name)"
        alert.informativeText = panels.map { "\($0.0) • \($0.1 ? "พร้อม" : "รออนุญาต")" }.joined(separator: "\n")
            + "\n\nเลือกสิทธิ์เพื่อเปิด System Settings หลังอนุญาตปุ่มลัดแล้วให้เปิด \(Brand.name) ใหม่"
        alert.addButton(withTitle: "ปิด")
        let missing = panels.filter { !$0.1 }
        for panel in missing { alert.addButton(withTitle: panel.0) }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue - 1
        if missing.indices.contains(index) {
            let selected = missing[index]
            requestSystemPermission(named: selected.2)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(selected.2)") {
                NSWorkspace.shared.open(url)
            }
        }
        // One post-dialog recheck follows the user's explicit System Settings action.
        // There is no permission polling or TCC mutation here.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.activateHotKeyWhenReady() }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func previewVisual() {
        guard !isHolding, streamer == nil else { return }
        let preview = UUID()
        hud.show(.recording, session: preview)
        hud.showDemoMeter(session: preview)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.hud.transition(to: .finishing, session: preview) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { [weak self] in self?.hud.finish(.inserted, session: preview) }
    }
    private func setStatus(_ value: String) { statusItem.button?.title = "🎙︎ " + value }
    private func requestSystemPermission(named panel: String) {
        switch panel {
        case "Privacy_ListenEvent":
            _ = CGRequestListenEventAccess()
        case "Privacy_Accessibility":
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case "Privacy_Microphone":
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        default:
            break
        }
    }
    private func activateHotKeyWhenReady() {
        guard !handoverInProgress, !hotKey.isRunning else { rebuildMenu(); return }
        guard CGPreflightListenEventAccess() else {
            setStatus("รออนุญาต Input Monitoring")
            rebuildMenu()
            return
        }
        guard AXIsProcessTrusted() else {
            setStatus("รออนุญาต Accessibility")
            rebuildMenu()
            return
        }
        hotKey.acceptsDictationEvents = true
        hotKey.start()
        guard hotKey.isRunning else {
            setStatus("เปิด Input Monitoring แล้วเปิด \(Brand.name) ใหม่")
            rebuildMenu()
            return
        }
        retireKnownLegacyAfterNewTap()
        rebuildMenu()
    }

    private func retireKnownLegacyAfterNewTap() {
        let legacyPath = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Thai Dictation.app").standardizedFileURL.path
        let legacyApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.pngoung.thaidictation").filter {
            $0.bundleURL?.standardizedFileURL.path == legacyPath
        }
        guard !legacyApps.isEmpty else { return }
        handoverInProgress = true
        hotKey.acceptsDictationEvents = false
        guard legacyApps.allSatisfy({ $0.terminate() }) else {
            hotKey.stop()
            handoverInProgress = false
            setStatus("Thai Dictation ยังทำงานอยู่")
            rebuildMenu()
            return
        }
        observeLegacyTermination(legacyApps, remainingChecks: 15)
    }

    private func observeLegacyTermination(_ legacyApps: [NSRunningApplication], remainingChecks: Int) {
        if legacyApps.allSatisfy({ $0.isTerminated }) {
            handoverInProgress = false
            hotKey.acceptsDictationEvents = true
            setStatus("พร้อมพูด")
            rebuildMenu()
            return
        }
        guard remainingChecks > 0 else {
            handoverInProgress = false
            hotKey.stop()
            setStatus("Thai Dictation ยังไม่ยอมปิด")
            rebuildMenu()
            return
        }
        // Bounded grace for normal app termination. This stops after three seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.observeLegacyTermination(legacyApps, remainingChecks: remainingChecks - 1)
        }
    }
    private func argumentURL(_ flag: String) -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }
    private func renderDirectory() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--hud-render"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    @objc private func activatedApplication(_ notification: Notification) {
        guard let target, !didInsert, !wasCancelled,
              let active = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              active.processIdentifier != target.pid else { return }
        destinationLeft = true
    }

    private func reviewSettingsChanged() {
        capturedReview = nil
        guard reviewDelivery.isWaiting, let session else { return }
        reviewDelivery.cancel()
        wordReview.setReviewResultNote("เปลี่ยนการตั้งค่าแล้ว คัดลอกข้อความจาก Local AI ได้ในเมนู")
        didInsert = true
        presentInsertion("settings_changed_copy", session: session)
    }

    func hotKeyDown() -> Bool {
        if reviewDelivery.isWaiting {
            setStatus("AI กำลังตรวจคำ • กด Esc เพื่อยกเลิก")
            return false
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            setStatus("รออนุญาตไมโครโฟน")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async { self?.setStatus(granted ? "กดค้างอีกครั้งเพื่อพูด" : "กรุณาเปิดสิทธิ์ไมโครโฟน") }
            }
            return false
        case .authorized: break
        default:
            setStatus("กรุณาเปิดสิทธิ์ไมโครโฟน")
            return false
        }
        if LocalAIService.state == .missingRuntime { LocalAIInstallWindow.show { PinkStudio.refreshIfVisible() }; return false }
        if LocalAIService.state != .ready && LocalAIService.state != .starting { Task { @MainActor in await LocalAIService.ensureRunning() } }
        guard !isHolding, streamer == nil else { return false }; isHolding = true; wasCancelled = false; didInsert = false; finals.removeAll()
        assessments.removeAll()
        capturedReview = wordReview.finalReviewConfiguration
        usedLocalFallback = false
        destinationLeft = false
        voice = VoiceActivity()
        silenceTimer?.invalidate()
        wordReview.beginDictation()
        session = UUID(); target = nil; releaseUptime = nil; setStatus("กำลังฟัง")
        guard let session else { return false }; Telemetry.shared.record(session, "press")
        hud.show(.recording, session: session)
        let stream = AudioStreamer(sessionID: session); stream.delegate = self; streamer = stream
        do { try stream.begin(endpoint: settings.endpoint, language: settings.language) } catch { failed(error.localizedDescription) }
        return isHolding
    }
    func hotKeyUp() {
        guard isHolding else { return }; isHolding = false; guard let session else { return }
        let releasedAt = ProcessInfo.processInfo.systemUptime
        releaseUptime = releasedAt
        target = FocusSnapshot.capture(); Telemetry.shared.record(session, "release", target == nil ? "no_safe_focus" : "safe_focus"); setStatus("กำลังเรียบเรียง"); hud.show(.finishing, session: session); streamer?.finish()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: slowResponseInterval, repeats: false) { [weak self] _ in
            guard let self, self.session == session, self.streamer != nil else { return }
            let remaining = releasedAt + self.responseTimeout - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { self.deadline(); return }
            Telemetry.shared.record(session, "waiting_for_asr")
            self.setStatus(PinkVoiceHUD.State.waiting.message)
            self.hud.transition(to: .waiting, session: session)
            self.timer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                guard self?.session == session else { return }
                self?.deadline()
            }
        }
        // Nothing was heard while holding: stop waiting soon instead of the full timeout.
        silenceTimer?.invalidate()
        guard !voice.heardVoice else { return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: VoiceActivity.silenceCutoff, repeats: false) { [weak self] _ in
            guard let self, self.session == session, self.streamer != nil, !self.wasCancelled,
                  self.finals.isEmpty, !self.voice.heardVoice else { return }
            self.dropSilentUtterance(session)
        }
    }
    private func dropSilentUtterance(_ session: UUID) {
        Telemetry.shared.record(session, "no_voice_cutoff")
        timer?.invalidate()
        streamer?.cancel()
        streamer = nil
        setStatus("ไม่พบเสียงพูด")
        hud.finish(.noSpeech, session: session, hideAfter: 1.4)
    }
    func quickFixChord() {
        DispatchQueue.main.async { [weak self] in
            if QuickFixPanel.isShowing { QuickFixPanel.dismiss() } else { self?.quickFix() }
        }
    }
    func cancelDictation() {
        guard streamer != nil || reviewDelivery.isWaiting, let session else { return }
        wasCancelled = true
        isHolding = false
        timer?.invalidate()
        silenceTimer?.invalidate()
        streamer?.cancel()
        streamer = nil
        reviewDelivery.cancel()
        Telemetry.shared.record(session, "cancel")
        setStatus("ยกเลิกแล้ว")
        hud.cancel(session: session)
    }
    private func deadline() { guard let session, !wasCancelled else { return }; Telemetry.shared.record(session, "deadline"); streamer?.cancel(); streamer = nil; retainForCopy(session, emptyState: .timedOut) }
    func asrReady(_ source: AudioStreamer) { DispatchQueue.main.async { guard self.streamer === source, self.isHolding, !self.wasCancelled, let session = self.session else { return }; Telemetry.shared.record(session, "asr_ready"); self.setStatus("กำลังฟัง"); self.hud.show(.recording, session: session) } }
    func asrPartial(_ text: String, source: AudioStreamer) { DispatchQueue.main.async { guard self.streamer === source, self.isHolding, !self.wasCancelled else { return }; self.voice.record(text: text); self.setStatus("กำลังฟัง") } }
    func asrAudioLevel(_ level: CGFloat, source: AudioStreamer) { DispatchQueue.main.async { guard self.streamer === source, self.isHolding, !self.wasCancelled, let session = self.session else { return }; self.voice.record(level: level); self.hud.setLevel(level, session: session) } }
    func asrFinal(_ text: String, assessment: DictationAssessment?, source: AudioStreamer) {
        DispatchQueue.main.async {
            guard self.streamer === source, !self.wasCancelled, !text.isEmpty, let session = self.session else { return }
            self.finals.append(text)
            self.voice.record(text: text)
            self.assessments.append(assessment)
            Telemetry.shared.record(session, "final_received")
            if let assessment {
                let limited = assessment.confidence_kind == "limited_stream_agreement"
                let detail = "score=\(assessment.heuristic_score) decision=\(assessment.decision) flags=\(assessment.uncertain_spans.count) limited=\(limited)"
                Telemetry.shared.record(session, "word_score", detail)
            }
        }
    }
    func asrDone(_ source: AudioStreamer) { DispatchQueue.main.async { guard self.streamer === source, !self.wasCancelled else { return }; self.finish(nil) } }
    func asrError(_ message: String, source: AudioStreamer) { DispatchQueue.main.async { guard self.streamer === source, !self.wasCancelled else { return }; self.failed(message) } }
    private func failed(_ message: String) {
        isHolding = false
        timer?.invalidate()
        if let session { Telemetry.shared.record(session, "error", message); retainForCopy(session, emptyState: .failed) }
        streamer?.cancel(); streamer = nil
    }
    private func finish(_ note: String?) {
        timer?.invalidate(); guard let session else { return }; streamer = nil
        let heard = finals.joined(separator: " ")
        let text = TextCleanup.finalText(heard, settings: settings)
        guard !text.isEmpty else { Telemetry.shared.record(session, "no_final"); hud.finish(.noSpeech, session: session, hideAfter: 3); setStatus(note ?? "ไม่พบคำพูด"); return }
        lastHeard = heard
        lastText = text
        wordReview.finish(assessments, settings: settings, heard: heard)
        guard !didInsert, !wasCancelled else { return }
        guard let configuration = capturedReview, configuration == wordReview.finalReviewConfiguration,
              configuration.isOnline, let model = configuration.model else {
            commit(text, session: session, afterReview: false)
            return
        }
        guard !destinationLeft, let target, target.stillMatches() else {
            commit(text, session: session, afterReview: true)
            return
        }
        let input = prepareReview(text, writingNote: configuration.writingNote)
        Telemetry.shared.record(session, "brand_context", "candidates=\(input.contextualBrands.count)")
        setStatus("AI กำลังตรวจคำ")
        hud.transition(to: .checking, session: session)
        Telemetry.shared.record(session, "online_review_start", model)
        let start = ProcessInfo.processInfo.systemUptime
        reviewDelivery.start(work: {
            let usesPlan = configuration.keySource == .chatGPT
            let resolved: String? = usesPlan ? await ChatGPTAccount.shared.accessToken()
                : await Task.detached(priority: .userInitiated, operation: { FinalReviewKeys.resolve(configuration.keySource) }).value
            guard let key = resolved else { return .fallback(.missingKey) }
            guard !Task.isCancelled else { return .fallback(.cancelled) }
            let monitored = TranscriptFinalizerTransport { request in
                try Task.checkCancellation()
                Telemetry.shared.record(session, "online_post", model)
                let (data, response) = try await TranscriptFinalizerTransport.live.send(request)
                Telemetry.shared.record(session, "online_http", "\(model) HTTP \(response.statusCode)")
                return (data, response)
            }
            // ChatGPT plan usage is not an API bill, so it stays out of the Sol cost ledger.
            return await TranscriptFinalizer.finalize(input, model: model, apiKey: key, chatGPTPlan: usesPlan,
                transport: usesPlan ? monitored : monitored.recordingSolUsage(model: model, session: session))
        }) { [weak self] outcome in
            guard let self, self.session == session, !self.wasCancelled, !self.didInsert else { return }
            guard self.capturedReview == configuration, self.wordReview.finalReviewConfiguration == configuration else {
                self.didInsert = true
                self.presentInsertion("settings_changed_copy", session: session)
                return
            }
            switch outcome {
            case .success(let reviewed):
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let changed = reviewed != text
                self.wordReview.setReviewResultNote(String(format: "%@ ตรวจแล้วใน %.2f วินาที • %@", model, elapsed, changed ? "ปรับการสะกดหรือเว้นวรรค" : "คงข้อความเดิม"))
                Telemetry.shared.record(session, "online_review_success", String(format: "%@ ms=%d changed=%d", model, Int(elapsed * 1000), changed ? 1 : 0))
                self.commit(reviewed, session: session, afterReview: true)
            case .fallback(let reason):
                self.fallback(text, reason: reason.userMessage, session: session)
            }
        }
    }

    private func prepareReview(_ text: String, writingNote: String) -> TranscriptFinalizerInput {
        let available = wordReview.reviewSpans.filter { text.contains($0.text) }
        var choices = [TranscriptFinalizerCandidate]()
        for span in available where span.category == "brand" || span.category == "mixed_thai_english" {
            for spelling in (span.candidates ?? []).prefix(3) where spelling != span.text {
                let pair = TranscriptFinalizerCandidate(source: span.text, replacement: spelling)
                if !choices.contains(pair) && choices.count < 12 { choices.append(pair) }
            }
        }
        let taught = settings.dictionaryEnabled ? settings.dictionaryText.components(separatedBy: .newlines)
            .flatMap { (try? BrandDictionary.rows($0)) ?? [] } : []
        let glossary = BrandContext.bundled
        let keep = Set(taught.map(\.spelling).filter { text.contains($0) } + (glossary?.exactSpellings(in: text) ?? []))
        let brands = glossary?.candidates(in: text, taught: taught) ?? []
        let alike = SoundAlike.matches(in: text, terms: settings.soundAlikeList).filter { !$0.isExact }.prefix(6)
            .map { TranscriptFinalizerCandidate(source: $0.source, replacement: $0.spelling) }
        return TranscriptFinalizerInput(text: text, candidates: choices, protectedSpellings: keep.sorted(),
                                       contextualBrands: brands, soundAlikes: Array(alike), writingNote: writingNote)
    }

    private func fallback(_ text: String, reason: String, session: UUID) {
        usedLocalFallback = true
        wordReview.setReviewResultNote("ใช้ข้อความจาก Local AI • " + reason)
        Telemetry.shared.record(session, "online_review_fallback", reason)
        commit(text, session: session, afterReview: true)
    }

    private func commit(_ text: String, session: UUID, afterReview: Bool) {
        guard self.session == session, !didInsert, !wasCancelled else { return }
        didInsert = true
        lastText = text
        let late = releaseUptime.map { ProcessInfo.processInfo.systemUptime - $0 >= slowResponseInterval } ?? false
        let result: String
        if destinationLeft { result = "focus_changed_copy" }
        else if let target { result = SafeInserter.insert(text, target: target, requireOriginalSelection: afterReview || late, allowClipboardPaste: settings.allowClipboardPaste) }
        else { result = "no_target_copy" }
        if let target, result == "native_typing_attempted_unverified" || result == "paste_attempted_unverified" {
            let method = result == "paste_attempted_unverified" ? "paste" : "native_typing"
            SafeInserter.verifyNativeInsertion(text, target: target, method: method) { [weak self] outcome in
                self?.presentInsertion(outcome, session: session)
            }
        } else {
            presentInsertion(result, session: session)
        }
    }

    private func presentInsertion(_ result: String, session: UUID) {
        Telemetry.shared.record(session, "dispatch", result)
        guard self.session == session else { return }
        let state: PinkVoiceHUD.State
        switch result {
        case "ax_inserted", "native_typing_inserted", "paste_inserted": state = usedLocalFallback ? .localFallback : .inserted
        case "ax_attempted_unverified", "native_typing_attempted_unverified", "paste_attempted_unverified": state = .checkField
        default: state = .savedForCopy
        }
        setStatus(state.message + (wordReview.needsReview ? " • มีคำควรตรวจ" : ""))
        hud.finish(state, session: session)
    }
    private func retainForCopy(_ session: UUID, emptyState: PinkVoiceHUD.State) {
        let heard = finals.joined(separator: " ")
        lastText = TextCleanup.finalText(heard, settings: settings)
        if !lastText.isEmpty {
            lastHeard = heard
            wordReview.finish(assessments, settings: settings, heard: heard)
        }
        Telemetry.shared.record(session, "copy_only", lastText.isEmpty ? "empty" : "final_in_memory")
        let state: PinkVoiceHUD.State = lastText.isEmpty ? emptyState : .savedForCopy
        hud.finish(state, session: session, hideAfter: 3)
        setStatus(state.message)
    }
    private func fixture() {
        // Deterministic safety-path check: uses same finish/insert pipeline but never contacts ASR or records audio.
        session = UUID(); target = FocusSnapshot.capture(); finals = ["ส่งบรีฟ Pink Cuts ให้ LINE OA"]; didInsert = false; Telemetry.shared.record(session!, "fixture_start"); finish("fixture")
    }
}
