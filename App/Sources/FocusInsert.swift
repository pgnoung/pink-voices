import AppKit
import ApplicationServices
import IOKit.hidsystem
import Carbon

struct FocusSnapshot {
    let pid: pid_t
    let window: AXUIElement
    let element: AXUIElement
    let originalSelection: CFRange?
    let originalMarkerRange: CFTypeRef?
    let wasEmptyAtCapture: Bool
    let supportsDirectInsert: Bool
    let prefersNativeTyping: Bool

    static func selectedRange(in element: AXUIElement) -> CFRange? {
        var raw: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID(),
              AXValueGetValue(raw as! AXValue, .cfRange, &range),
              range.location >= 0 else { return nil }
        return range
    }

    private static func selectedMarkerRange(in element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &value) == .success else { return nil }
        return value
    }

    private static func characterCount(in element: AXUIElement) -> Int? {
        attribute(element, kAXNumberOfCharactersAttribute, as: NSNumber.self)?.intValue
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String, as type: T.Type) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    // Some apps expose their active editor on the application AX object while
    // the system-wide AXFocusedUIElement is unavailable. Bind both reads to
    // the same foreground application and reject any window/focus switch.
    private static func focusedEditor() -> (pid: pid_t, window: AXUIElement, element: AXUIElement)? {
        guard !IsSecureEventInputEnabled(),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        func read(_ object: AXUIElement, _ key: String) -> AXUIElement? {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(object, key as CFString, &raw) == .success,
                  let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return (raw as! AXUIElement)
        }
        guard let window = read(app, kAXFocusedWindowAttribute),
              let element = read(app, kAXFocusedUIElementAttribute) ?? read(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        if let owner = read(element, kAXWindowAttribute) {
            guard CFEqual(owner, window) else { return nil }
        } else {
            var ownerPID: pid_t = 0
            guard AXUIElementGetPid(element, &ownerPID) == .success, ownerPID == pid else { return nil }
        }
        return (pid, window, element)
    }

    static func capture() -> FocusSnapshot? {
        guard let (pid, window, element) = focusedEditor() else { return nil }
        let role: String? = attribute(element, kAXRoleAttribute, as: String.self)
        let editable: Bool? = attribute(element, "AXEditable", as: Bool.self)
        let selection = selectedRange(in: element)
        let markerRange = selectedMarkerRange(in: element)
        var settable = DarwinBoolean(false)
        let directInsertIsSettable = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
        let valueIsSettable = isAttributeSettable(element, kAXValueAttribute as String)
        let inWebArea = hasWebAreaAncestor(element)
        let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        guard !isProtectedOrSecure(element),
              !isTerminalLike(element, bundleIdentifier: bundleIdentifier),
              isEligibleEditor(
                  role: role,
                  editable: editable,
                  hasSelectedRange: selection != nil,
                  selectedTextIsSettable: directInsertIsSettable,
                  valueIsSettable: valueIsSettable,
                  inWebArea: inWebArea
              ) else { return nil }
        let supportsDirectInsert = directInsertIsSettable && (editable == true || isStandardEditableRole(role))
        // Selection-less editors remain eligible when AX explicitly says they are editable.
        // Native event insertion can preserve their caret, but its result remains unverified.
        let nativeEventPreferredBundles: Set<String> = [
            "com.openai.codex", "com.anthropic.claudefordesktop"
        ]
        let prefersNativeTyping = inWebArea || nativeEventPreferredBundles.contains(bundleIdentifier ?? "") || !supportsDirectInsert
        return FocusSnapshot(
            pid: pid,
            window: window,
            element: element,
            originalSelection: selection,
            originalMarkerRange: markerRange,
            wasEmptyAtCapture: characterCount(in: element) == 0,
            supportsDirectInsert: supportsDirectInsert,
            prefersNativeTyping: prefersNativeTyping
        )
    }

    static func isEligibleEditor(role: String?, editable: Bool?, hasSelectedRange: Bool, selectedTextIsSettable: Bool, valueIsSettable: Bool = false, inWebArea: Bool) -> Bool {
        guard editable != false, !isNonEditorRole(role) else { return false }
        if isStandardEditableRole(role) {
            if editable == true || selectedTextIsSettable || valueIsSettable { return true }
            // Older AX text fields (including legacy Codex fields) may omit AXEditable
            // while still exposing a caret. Do not extend this weak signal to text areas.
            return role == kAXTextFieldRole && hasSelectedRange
        }
        // A selection range alone occurs on static documents. Custom controls need
        // a positive AXEditable flag or a writable selected-text attribute.
        return editable == true || selectedTextIsSettable && inWebArea
    }

    func stillMatches() -> Bool {
        guard !IsSecureEventInputEnabled(), let now = FocusSnapshot.capture(), now.pid == pid else { return false }
        return CFEqual(now.window, window) && CFEqual(now.element, element)
    }

    /// Cheap per-keystroke focus check. Call `stillMatches()` before a commit or paste.
    /// Checks only caret metadata. It never reads the field's text or uses a broad fallback.
    func originalInsertionPointStillMatches() -> Bool {
        guard stillMatches() else { return false }
        if let originalSelection, let currentSelection = FocusSnapshot.selectedRange(in: element) {
            return originalSelection.location == currentSelection.location && originalSelection.length == currentSelection.length
        }
        if let originalMarkerRange, let currentMarkerRange = FocusSnapshot.selectedMarkerRange(in: element) {
            return CFEqual(originalMarkerRange, currentMarkerRange)
        }
        return originalSelection == nil && originalMarkerRange == nil && wasEmptyAtCapture && FocusSnapshot.characterCount(in: element) == 0
    }

    private static func isProtectedOrSecure(_ startingElement: AXUIElement) -> Bool {
        var current: AXUIElement? = startingElement
        for _ in 0..<32 {
            guard let element = current else { return false }
            let subrole: String? = attribute(element, kAXSubroleAttribute, as: String.self)
            let protected: Bool? = attribute(element, "AXProtectedContent", as: Bool.self)
            if subrole == "AXSecureTextField" || protected == true { return true }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return false }
            let parent = parentValue as! AXUIElement
            current = parent
        }
        return false
    }

    private static func hasWebAreaAncestor(_ startingElement: AXUIElement) -> Bool {
        var current: AXUIElement? = startingElement
        for _ in 0..<32 {
            guard let element = current else { return false }
            let role: String? = attribute(element, kAXRoleAttribute, as: String.self)
            if role == "AXWebArea" { return true }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return false }
            current = (parentValue as! AXUIElement)
        }
        return false
    }

    private static func isStandardEditableRole(_ role: String?) -> Bool {
        [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? "")
    }

    private static func isNonEditorRole(_ role: String?) -> Bool {
        [
            "AXStaticText", "AXWebArea", "AXDocument", "AXWindow", "AXGroup",
            "AXScrollArea", "AXList", "AXTable", "AXOutline", "AXBrowser"
        ].contains(role ?? "")
    }

    private static func isTerminalLike(_ element: AXUIElement, bundleIdentifier: String?) -> Bool {
        let knownTerminalBundles: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
            "com.github.wez.wezterm", "dev.warp.Warp-Stable", "org.alacritty"
        ]
        let role: String? = attribute(element, kAXRoleAttribute, as: String.self)
        let subrole: String? = attribute(element, kAXSubroleAttribute, as: String.self)
        let terminalRoles: Set<String> = ["AXTerminal", "AXCommandLine", "AXShell"]
        if terminalRoles.contains(role ?? "") || terminalRoles.contains(subrole ?? "") { return true }
        if let bundleIdentifier, knownTerminalBundles.contains(bundleIdentifier) {
            return role == kAXTextAreaRole || !isStandardEditableRole(role)
        }
        let terminalIdentifiers: Set<String> = ["terminal", "command-line", "commandline", "shell"]
        let identifier: String? = attribute(element, "AXIdentifier", as: String.self)
        return terminalIdentifiers.contains(identifier?.lowercased() ?? "")
    }
}

enum SafeInserter {

    static func insert(_ text: String, target: FocusSnapshot, requireOriginalSelection: Bool = false, allowClipboardPaste: Bool = false) -> String {
        guard target.stillMatches(), AXIsProcessTrusted() else { return "focus_changed_copy" }
        let selection = FocusSnapshot.selectedRange(in: target.element)
        if requireOriginalSelection {
            guard target.originalInsertionPointStillMatches() else { return "selection_changed_copy" }
        }
        guard target.stillMatches() else { return "focus_changed_copy" }
        guard isSafePasteText(text) else { return "manual_copy_required" }

        // This mode is explicit because it replaces the user's clipboard. Its
        // single paste attempt is intentionally preferred over all other routes.
        if allowClipboardPaste {
            return stageAndPaste(text, target: target)
        }

        // Some web editors accept a Unicode input event but report a successful
        // AX write without updating their own editor state. Keep that route first.
        if target.prefersNativeTyping {
            switch typeUnicode(text, target: target) {
            case .attempted: return "native_typing_attempted_unverified"
            case .unavailable: break
            }
        }
        if target.supportsDirectInsert {
            let status = AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if status == .success { return verifyAXInsertion(text, selection: selection, target: target) }
            // A timeout or general AX failure can follow a partial write. Only the
            // two capability rejections below may safely fall through to another send.
            guard isDefinitiveAXRejection(status) else { return "ax_attempted_unverified" }
        }
        // A direct AX write can be unavailable even on a standard editable control.
        // Try the same constrained Unicode route once, never after an attempted send.
        if !target.prefersNativeTyping {
            switch typeUnicode(text, target: target) {
            case .attempted: return "native_typing_attempted_unverified"
            case .unavailable: break
            }
        }
        return target.stillMatches() ? "manual_copy_required" : "focus_changed_copy"
    }

    /// Lets the caller update its status after the target app has applied a native event.
    /// It never reads more than the inserted range and cannot cause another insertion.
    static func verifyNativeInsertion(_ text: String, target: FocusSnapshot, method: String, completion: @escaping (String) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard target.stillMatches(), let selection = target.originalSelection else {
                completion("\(method)_attempted_unverified")
                return
            }
            var range = CFRange(location: selection.location, length: text.utf16.count)
            guard let value = AXValueCreate(.cfRange, &range) else {
                completion("\(method)_attempted_unverified")
                return
            }
            var rendered: CFTypeRef?
            let status = AXUIElementCopyParameterizedAttributeValue(target.element, kAXStringForRangeParameterizedAttribute as CFString, value, &rendered)
            completion(status == .success && (rendered as? String) == text ? "\(method)_inserted" : "\(method)_attempted_unverified")
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private enum NativeTypingResult { case attempted, unavailable }

    private static func typeUnicode(_ text: String, target: FocusSnapshot) -> NativeTypingResult {
        guard isSafeNativeText(text),
              CGPreflightPostEventAccess(),
              !hasPhysicalModifiers() else { return .unavailable }
        var sentCharacter = false
        for character in text {
            guard target.stillMatches(), let down = unicodeEvent(for: String(character), down: true), let up = unicodeEvent(for: String(character), down: false) else {
                return sentCharacter ? .attempted : .unavailable
            }
            down.postToPid(target.pid)
            up.postToPid(target.pid)
            sentCharacter = true
        }
        return .attempted
    }

    static func isSafeNativeText(_ text: String) -> Bool {
        !text.isEmpty && !requiresTargetedPaste(text)
    }

    /// Multiline and very long text is never emitted as individual Unicode key events.
    /// It can use the guarded, opt-in paste route; otherwise the caller keeps it for copy.
    static func requiresTargetedPaste(_ text: String) -> Bool {
        text.count > 1_200 || text.unicodeScalars.contains {
            $0.properties.generalCategory == .control ||
            $0.properties.generalCategory == .lineSeparator ||
            $0.properties.generalCategory == .paragraphSeparator
        }
    }

    static func isSafePasteText(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains {
            $0.properties.generalCategory == .control && $0.value != 9 && $0.value != 10 && $0.value != 13
        }
    }

    static func isDefinitiveAXRejection(_ status: AXError) -> Bool {
        status == .attributeUnsupported || status == .notImplemented
    }

    struct PasteboardStage {
        let changeCount: Int
        let expectedText: String
    }

    private static func stageAndPaste(_ text: String, target: FocusSnapshot) -> String {
        guard target.originalInsertionPointStillMatches(), !hasPhysicalModifiers(),
              let stage = stagePasteboard(text) else {
            return target.stillMatches() ? "manual_copy_required" : "focus_changed_copy"
        }
        return sendPaste(to: target, stage: stage) ? "paste_attempted_unverified" : "manual_copy_required"
    }

    static func stagePasteboard(_ text: String, on board: NSPasteboard = .general) -> PasteboardStage? {
        board.clearContents()
        guard board.writeObjects([text as NSString]) else { return nil }
        let stage = PasteboardStage(changeCount: board.changeCount, expectedText: text)
        return owns(stage, on: board) ? stage : nil
    }

    static func owns(_ stage: PasteboardStage, on board: NSPasteboard = .general) -> Bool {
        guard board.changeCount == stage.changeCount else { return false }
        return board.string(forType: .string) == stage.expectedText && board.changeCount == stage.changeCount
    }

    private static func sendPaste(to target: FocusSnapshot, stage: PasteboardStage) -> Bool {
        guard CGPreflightPostEventAccess(),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        guard target.originalInsertionPointStillMatches(), !hasPhysicalModifiers(), owns(stage, on: .general) else { return false }
        down.postToPid(target.pid)
        up.postToPid(target.pid)
        return true  // Delivery is now ambiguous until the target reports the inserted range.
    }

    private static func unicodeEvent(for text: String, down: Bool) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { return nil }
        let units = Array(text.utf16)
        event.flags = []
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        return event
    }

    private static func hasPhysicalModifiers() -> Bool {
        [55, 54, 56, 60, 58, 61, 59, 62].contains { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
    }

    private static func verifyAXInsertion(_ text: String, selection: CFRange?, target: FocusSnapshot) -> String {
        guard let selection else { return "ax_attempted_unverified" }
        var insertedRange = CFRange(location: selection.location, length: text.utf16.count)
        guard let range = AXValueCreate(.cfRange, &insertedRange) else { return "ax_attempted_unverified" }
        var rendered: CFTypeRef?
        let readback = AXUIElementCopyParameterizedAttributeValue(target.element, kAXStringForRangeParameterizedAttribute as CFString, range, &rendered)
        return readback == .success && (rendered as? String) == text ? "ax_inserted" : "ax_attempted_unverified"
    }

}
