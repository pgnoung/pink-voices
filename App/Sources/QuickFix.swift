import AppKit
import ApplicationServices
import Carbon

/// Highlight a wrong word anywhere, tap Control + Option together, type the right spelling, Enter.
/// Pink voices remembers it (optionally as a brand/name with sound-alike matching)
/// and, when it safely can, replaces the highlighted word in place.
enum QuickFix {
    /// Set from Settings at launch and whenever the person changes it.
    static var chord: QuickFixChord = .controlOption
    static var shortcutTitle: String { chord.symbols }
    static var shortcutWords: String { chord.words }

    struct Selection {
        let text: String
        let target: FocusSnapshot?
        let app: NSRunningApplication?
    }

    /// Reads the highlighted text through Accessibility; falls back to a one-off ⌘C
    /// whose clipboard contents are restored right after.
    static func grabSelection(completion: @escaping (Selection) -> Void) {
        let app = NSWorkspace.shared.frontmostApplication
        let target = FocusSnapshot.capture()
        if let text = selectedText(), !text.isEmpty {
            completion(Selection(text: text, target: target, app: app)); return
        }
        guard AXIsProcessTrusted(), app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            completion(Selection(text: "", target: target, app: app)); return
        }
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        } ?? []
        let before = board.changeCount
        func finish(_ attempt: Int) {
            if board.changeCount != before || attempt >= 8 {
                let text = board.changeCount != before ? (board.string(forType: .string) ?? "") : ""
                if board.changeCount != before {
                    board.clearContents()
                    board.writeObjects(saved.map { values -> NSPasteboardItem in
                        let item = NSPasteboardItem()
                        for (type, data) in values { item.setData(data, forType: type) }
                        return item
                    })
                }
                completion(Selection(text: clean(text), target: target, app: app))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { finish(attempt + 1) }
        }
        // The shortcut's ⌃⌥ are still held when it fires; copy once they are released.
        func copyWhenReleased(_ attempt: Int) {
            let held = CGEventSource.flagsState(.combinedSessionState).intersection([.maskControl, .maskAlternate, .maskShift])
            guard held.isEmpty || attempt >= 12 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { copyWhenReleased(attempt + 1) }
                return
            }
            postCopy()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { finish(0) }
        }
        copyWhenReleased(0)
    }

    static func clean(_ text: String) -> String {
        let single = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !single.contains(where: \.isNewline), single.count <= 80 else { return "" }
        return single
    }

    private static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String else { return nil }
        return clean(text)
    }

    private static func postCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}

/// The small floating card that teaches one word.
final class QuickFixPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    struct Result { let heard: String; let written: String; let soundAlike: Bool; let replaceInPlace: Bool }

    private static var current: QuickFixPanel?
    static var isShowing: Bool { current?.panel.isVisible == true }
    /// Second tap of the shortcut: close the card and go back to the app the person was in.
    static func dismiss() { current?.panel.close() }
    private let panel: NSPanel
    private let heardField = NSTextField()
    private let writtenField = NSTextField()
    private let brandBox = NSButton(checkboxWithTitle: "เป็นชื่อแบรนด์หรือชื่อคน ให้จับเสียงที่คล้ายกันด้วย", target: nil, action: nil)
    private let replaceBox = NSButton(checkboxWithTitle: "แก้คำนี้ในข้อความที่ไฮไลต์ด้วย", target: nil, action: nil)
    private let note = StudioText.label("", PinkTheme.rounded(11.5, .medium), PinkTheme.textSecondary)
    private let onSave: (Result) -> Bool
    private let returnTo: NSRunningApplication?

    static func present(heard: String, suggestion: String?, isBrand: Bool, canReplace: Bool,
                        returnTo: NSRunningApplication?, onSave: @escaping (Result) -> Bool) {
        current?.panel.close()
        let card = QuickFixPanel(heard: heard, suggestion: suggestion, isBrand: isBrand, canReplace: canReplace,
                                 returnTo: returnTo, onSave: onSave)
        current = card
        NSApp.activate(ignoringOtherApps: true)
        card.panel.center()
        if let screen = NSScreen.main?.visibleFrame {
            card.panel.setFrameOrigin(NSPoint(x: screen.midX - card.panel.frame.width / 2, y: screen.maxY - card.panel.frame.height - 120))
        }
        card.panel.makeKeyAndOrderFront(nil)
        card.panel.makeFirstResponder(heard.isEmpty ? card.heardField : card.writtenField)
    }

    private init(heard: String, suggestion: String?, isBrand: Bool, canReplace: Bool,
                 returnTo: NSRunningApplication?, onSave: @escaping (Result) -> Bool) {
        self.onSave = onSave
        self.returnTo = returnTo
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 318),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.title = "แก้คำ"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        PinkTheme.style(panel)
        build(heard: heard, suggestion: suggestion, isBrand: isBrand, canReplace: canReplace)
    }

    private func build(heard: String, suggestion: String?, isBrand: Bool, canReplace: Bool) {
        let backdrop = StudioBackdrop()
        panel.contentView = backdrop
        let eyebrow = StudioText.eyebrow("Quick fix · \(QuickFix.shortcutTitle)")
        let title = StudioText.label("สอนคำที่ถอดผิด", PinkTheme.rounded(22, .heavy))
        for (field, placeholder) in [(heardField, "คำที่ระบบพิมพ์ผิด"), (writtenField, "คำที่ถูก เช่น Gentlewoman")] {
            field.placeholderString = placeholder
            field.font = PinkTheme.rounded(16, .semibold)
            field.bezelStyle = .roundedBezel
            field.focusRingType = .default
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 412).isActive = true
        }
        heardField.stringValue = heard
        writtenField.stringValue = suggestion ?? ""
        heardField.setAccessibilityLabel("คำที่ได้ยิน")
        writtenField.setAccessibilityLabel("คำที่ถูก")
        brandBox.state = isBrand ? .on : .off
        replaceBox.state = canReplace ? .on : .off
        replaceBox.isEnabled = canReplace
        for box in [brandBox, replaceBox] { box.font = PinkTheme.rounded(12.5, .medium) }
        note.stringValue = heard.isEmpty ? "ไม่พบคำที่ไฮไลต์ พิมพ์คำที่ระบบพิมพ์ผิดเองได้เลย" : "Enter เพื่อบันทึก · Esc เพื่อปิด"
        let save = PinkButton("จำคำนี้", style: .primary, symbol: "sparkles") { [weak self] in self?.commit() }
        save.keyEquivalent = "\r"
        let cancel = PinkButton("ยกเลิก") { [weak self] in self?.panel.close() }
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [note, NSView(), cancel, save])
        buttons.spacing = 10
        let stack = NSStackView(views: [eyebrow, title, label("ได้ยินเป็น"), heardField, label("ที่ถูกคือ"), writtenField, brandBox, replaceBox, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(2, after: eyebrow)
        stack.setCustomSpacing(14, after: title)
        stack.setCustomSpacing(12, after: heardField)
        stack.setCustomSpacing(14, after: writtenField)
        stack.setCustomSpacing(16, after: replaceBox)
        stack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 34),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -34),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 30),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func label(_ text: String) -> NSTextField {
        StudioText.label(text, PinkTheme.rounded(11.5, .bold), PinkTheme.rose)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { commit(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { panel.close(); return true }
        return false
    }

    private func commit() {
        let result = Result(heard: heardField.stringValue, written: writtenField.stringValue,
                            soundAlike: brandBox.state == .on, replaceInPlace: replaceBox.state == .on && replaceBox.isEnabled)
        guard onSave(result) else {
            note.stringValue = "ใส่ทั้งสองช่อง และต้องไม่เหมือนกัน"
            note.textColor = PinkTheme.coral
            NSSound.beep()
            return
        }
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        returnTo?.activate()
        if QuickFixPanel.current === self { QuickFixPanel.current = nil }
    }

    /// Visual QA without a hotkey or focus change.
    static func render(to url: URL) throws {
        let card = QuickFixPanel(heard: "โทรวูเม่น", suggestion: "Gentlewoman", isBrand: true, canReplace: true, returnTo: nil) { _ in true }
        guard let content = card.panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
