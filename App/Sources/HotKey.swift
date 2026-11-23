import Cocoa
import IOKit.hidsystem

enum HoldKey: UInt16, CaseIterable {
    case rightOption = 61
    case f8 = 100
    case f7 = 98

    var title: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .f8: return "F8"
        case .f7: return "F7"
        }
    }
}

/// Two modifier keys tapped together (pressed and released, nothing else) open the quick-fix card.
enum QuickFixChord: String, CaseIterable {
    case controlOption, controlShift, optionShift, controlCommand, optionCommand, off

    var flags: CGEventFlags {
        switch self {
        case .controlOption: return [.maskControl, .maskAlternate]
        case .controlShift: return [.maskControl, .maskShift]
        case .optionShift: return [.maskAlternate, .maskShift]
        case .controlCommand: return [.maskControl, .maskCommand]
        case .optionCommand: return [.maskAlternate, .maskCommand]
        case .off: return []
        }
    }

    var symbols: String {
        switch self {
        case .controlOption: return "⌃⌥"
        case .controlShift: return "⌃⇧"
        case .optionShift: return "⌥⇧"
        case .controlCommand: return "⌃⌘"
        case .optionCommand: return "⌥⌘"
        case .off: return ""
        }
    }

    var words: String {
        switch self {
        case .controlOption: return "Control + Option"
        case .controlShift: return "Control + Shift"
        case .optionShift: return "Option + Shift"
        case .controlCommand: return "Control + Command"
        case .optionCommand: return "Option + Command"
        case .off: return "ปิดปุ่มลัด"
        }
    }

    var menuTitle: String { self == .off ? words : "\(symbols)  \(words)" }
}

protocol HotKeyDelegate: AnyObject {
    func hotKeyDown() -> Bool
    func hotKeyUp()
    func cancelDictation()
    /// Control and Option pressed together and released with no other key: quick fix.
    func quickFixChord()
}

extension HotKeyDelegate {
    func quickFixChord() {}
}

final class EventTap: NSObject {
    weak var delegate: HotKeyDelegate?
    var chord: QuickFixChord = .controlOption { didSet { chordArmed = false; chordSpoiled = false } }
    var key: HoldKey = .rightOption {
        didSet {
            if oldValue != key { resetHold() }
        }
    }

    private var source: CFMachPort?
    private var runLoop: CFRunLoopSource?
    private var rightOptionDown = false
    private var rightOptionRecording = false
    private var functionKeyDown = false
    private var functionKeyRecording = false
    private let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskSecondaryFn]
    private var chordArmed = false
    private var chordSpoiled = false
    private var chordStarted: TimeInterval = 0
    static let chordLimit: TimeInterval = 1.5
    var acceptsDictationEvents = true

    var isRunning: Bool { source.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() {
        stop()
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        source = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<EventTap>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.resetHold()
                if let source = owner.source { CGEvent.tapEnable(tap: source, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let autoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let pass = owner.process(type: type, code: code, flags: event.flags, autoRepeat: autoRepeat)
            return pass ? Unmanaged.passUnretained(event) : nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let source else { return }
        runLoop = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, source, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoop, .commonModes)
        CGEvent.tapEnable(tap: source, enable: true)
    }

    /// Releases only this process's listener when a known legacy listener
    /// remains active during migration.
    func stop() {
        resetHold()
        if let source { CGEvent.tapEnable(tap: source, enable: false) }
        if let runLoop { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoop, .commonModes) }
        runLoop = nil
        source = nil
    }

    // Returns true when macOS should keep receiving the original event.
    func process(type: CGEventType, code: UInt16, flags: CGEventFlags = [], autoRepeat: Bool = false) -> Bool {
        guard acceptsDictationEvents else { return true }
        trackQuickFixChord(type: type, flags: flags)
        if type == .keyDown && code == 53 {
            rightOptionRecording = false
            functionKeyRecording = false
            delegate?.cancelDictation()
            return true
        }

        if key == .rightOption {
            if type == .flagsChanged && code == key.rawValue {
                handleRightOption(flags)
            } else if type == .keyDown || type == .flagsChanged {
                cancelOptionRecording()
            }
            return true
        }

        guard code == key.rawValue else { return true }
        if type == .keyDown {
            if !autoRepeat && !functionKeyDown {
                functionKeyDown = true
                functionKeyRecording = delegate?.hotKeyDown() == true
            }
            return false
        }
        if type == .keyUp {
            functionKeyDown = false
            if functionKeyRecording {
                functionKeyRecording = false
                delegate?.hotKeyUp()
            }
            return false
        }
        return true
    }

    private func handleRightOption(_ flags: CGEventFlags) {
        let isDown = flags.rawValue & UInt64(NX_DEVICERALTKEYMASK) != 0
        guard isDown != rightOptionDown else { return }
        rightOptionDown = isDown
        if isDown {
            let leftOptionDown = flags.rawValue & UInt64(NX_DEVICELALTKEYMASK) != 0
            if !leftOptionDown && flags.intersection(shortcutModifiers).isEmpty {
                rightOptionRecording = delegate?.hotKeyDown() == true
            }
        } else if rightOptionRecording {
            rightOptionRecording = false
            delegate?.hotKeyUp()
        }
    }

    /// ⌃⌥ tapped on its own. Any other key in between (⌃⌥← and similar app shortcuts)
    /// or an added ⌘/⇧/fn disarms it, so other shortcuts keep working.
    private func trackQuickFixChord(type: CGEventType, flags: CGEventFlags) {
        let wanted = chord.flags
        guard !wanted.isEmpty else { chordArmed = false; return }
        let watched: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        let held = flags.intersection(watched)
        if type == .keyDown || type == .keyUp || !held.subtracting(wanted).isEmpty {
            // Spoiled until the chord keys are let go, so it cannot re-arm mid-shortcut.
            if !held.isEmpty || chordArmed { chordSpoiled = true }
            chordArmed = false
            return
        }
        guard type == .flagsChanged else { return }
        if held.isEmpty {
            defer { chordArmed = false; chordSpoiled = false }
            if chordArmed, !chordSpoiled, ProcessInfo.processInfo.systemUptime - chordStarted <= Self.chordLimit {
                delegate?.quickFixChord()
            }
            return
        }
        if held == wanted && !chordArmed && !chordSpoiled {
            chordArmed = true
            chordStarted = ProcessInfo.processInfo.systemUptime
        }
    }

    private func cancelOptionRecording() {
        guard rightOptionRecording else { return }
        rightOptionRecording = false
        delegate?.cancelDictation()
    }

    private func resetHold() {
        if rightOptionRecording || functionKeyRecording { delegate?.cancelDictation() }
        rightOptionDown = false
        rightOptionRecording = false
        chordArmed = false
        chordSpoiled = false
        functionKeyDown = false
        functionKeyRecording = false
    }
}
