import Cocoa

@main
struct HotKeyCheck {
    static func main() {
        checkRightOption()
        checkRightOptionCancellation()
        checkFunctionKeys()
        checkQuickFixChord()
        print("HotKeyCheck passed")
    }

    private static func checkRightOption() {
        let recorder = Recorder()
        let tap = EventTap()
        tap.delegate = recorder
        let rightDown = optionFlags(NX_DEVICERALTKEYMASK)
        let leftHeldAfterRightUp = optionFlags(NX_DEVICELALTKEYMASK)

        expect(tap.process(type: .flagsChanged, code: HoldKey.rightOption.rawValue, flags: rightDown))
        expect(recorder.starts == 1)
        expect(tap.process(type: .flagsChanged, code: HoldKey.rightOption.rawValue, flags: rightDown))
        expect(recorder.starts == 1)
        expect(tap.process(type: .flagsChanged, code: HoldKey.rightOption.rawValue, flags: leftHeldAfterRightUp))
        expect(recorder.finishes == 1)

        let leftOnly = optionFlags(NX_DEVICELALTKEYMASK)
        expect(tap.process(type: .flagsChanged, code: 58, flags: leftOnly))
        expect(recorder.starts == 1)
    }

    private static func checkRightOptionCancellation() {
        do {
            let recorder = Recorder()
            let tap = EventTap()
            tap.delegate = recorder
            let rightDown = optionFlags(NX_DEVICERALTKEYMASK)
            let rightUp = CGEventFlags([])
            _ = tap.process(type: .flagsChanged, code: HoldKey.rightOption.rawValue, flags: rightDown)
            _ = tap.process(type: .keyDown, code: 0)
            _ = tap.process(type: .flagsChanged, code: HoldKey.rightOption.rawValue, flags: rightUp)
            expect(recorder.starts == 1)
            expect(recorder.cancels == 1)
            expect(recorder.finishes == 0)
        }

        do {
            let recorder = Recorder()
            let tap = EventTap()
            tap.delegate = recorder
            let rightAndShift = optionFlags(NX_DEVICERALTKEYMASK).union(.maskShift)
            _ = tap.process(type: .flagsChanged, code: HoldKey.rightOption.rawValue, flags: rightAndShift)
            _ = tap.process(type: .flagsChanged, code: HoldKey.rightOption.rawValue, flags: [])
            expect(recorder.starts == 0)
            expect(recorder.finishes == 0)
            expect(recorder.cancels == 0)
        }

        do {
            let recorder = Recorder()
            let tap = EventTap()
            tap.delegate = recorder
            _ = tap.process(type: .flagsChanged, code: HoldKey.rightOption.rawValue, flags: optionFlags(NX_DEVICERALTKEYMASK))
            expect(tap.process(type: .keyDown, code: 53))
            _ = tap.process(type: .flagsChanged, code: HoldKey.rightOption.rawValue, flags: [])
            expect(recorder.starts == 1)
            expect(recorder.cancels == 1)
            expect(recorder.finishes == 0)
        }
    }

    private static func checkFunctionKeys() {
        for key in [HoldKey.f8, .f7] {
            let recorder = Recorder()
            let tap = EventTap()
            tap.key = key
            tap.delegate = recorder

            expect(!tap.process(type: .keyDown, code: key.rawValue))
            expect(!tap.process(type: .keyDown, code: key.rawValue, autoRepeat: true))
            expect(!tap.process(type: .keyUp, code: key.rawValue))
            expect(!tap.process(type: .keyUp, code: key.rawValue))
            expect(recorder.starts == 1)
            expect(recorder.finishes == 1)
            expect(tap.process(type: .keyDown, code: 0))
        }

        let recorder = Recorder(startAllowed: false)
        let tap = EventTap()
        tap.key = .f8
        tap.delegate = recorder
        expect(!tap.process(type: .keyDown, code: HoldKey.f8.rawValue))
        expect(!tap.process(type: .keyUp, code: HoldKey.f8.rawValue))
        expect(recorder.starts == 1)
        expect(recorder.finishes == 0)
    }

    private static func checkQuickFixChord() {
        let recorder = Recorder()
        let tap = EventTap()
        tap.delegate = recorder
        let control = CGEventFlags.maskControl
        let both: CGEventFlags = [.maskControl, .maskAlternate]
        // Control, then left Option, released together: one quick fix, no dictation.
        _ = tap.process(type: .flagsChanged, code: 59, flags: control)
        _ = tap.process(type: .flagsChanged, code: 58, flags: both)
        _ = tap.process(type: .flagsChanged, code: 58, flags: control)
        _ = tap.process(type: .flagsChanged, code: 59, flags: [])
        expect(recorder.quickFixes == 1 && recorder.starts == 0)
        // ⌃⌥ plus another key is someone else's shortcut.
        _ = tap.process(type: .flagsChanged, code: 59, flags: control)
        _ = tap.process(type: .flagsChanged, code: 58, flags: both)
        _ = tap.process(type: .keyDown, code: 123, flags: both)
        _ = tap.process(type: .keyUp, code: 123, flags: both)
        _ = tap.process(type: .flagsChanged, code: 58, flags: control)
        _ = tap.process(type: .flagsChanged, code: 59, flags: [])
        expect(recorder.quickFixes == 1)
        // Adding Command or Shift disarms it too.
        _ = tap.process(type: .flagsChanged, code: 59, flags: control)
        _ = tap.process(type: .flagsChanged, code: 58, flags: both)
        _ = tap.process(type: .flagsChanged, code: 55, flags: [.maskControl, .maskAlternate, .maskCommand])
        _ = tap.process(type: .flagsChanged, code: 55, flags: both)
        _ = tap.process(type: .flagsChanged, code: 58, flags: [])
        expect(recorder.quickFixes == 1)
        // Control alone, or Option alone, does nothing.
        _ = tap.process(type: .flagsChanged, code: 59, flags: control)
        _ = tap.process(type: .flagsChanged, code: 59, flags: [])
        expect(recorder.quickFixes == 1)
        // A different chord can be chosen; the old one then does nothing.
        tap.chord = .controlShift
        _ = tap.process(type: .flagsChanged, code: 59, flags: control)
        _ = tap.process(type: .flagsChanged, code: 58, flags: both)
        _ = tap.process(type: .flagsChanged, code: 58, flags: control)
        _ = tap.process(type: .flagsChanged, code: 59, flags: [])
        expect(recorder.quickFixes == 1)
        _ = tap.process(type: .flagsChanged, code: 59, flags: control)
        _ = tap.process(type: .flagsChanged, code: 56, flags: [.maskControl, .maskShift])
        _ = tap.process(type: .flagsChanged, code: 56, flags: control)
        _ = tap.process(type: .flagsChanged, code: 59, flags: [])
        expect(recorder.quickFixes == 2)
        // Off never fires.
        tap.chord = .off
        _ = tap.process(type: .flagsChanged, code: 59, flags: control)
        _ = tap.process(type: .flagsChanged, code: 56, flags: [.maskControl, .maskShift])
        _ = tap.process(type: .flagsChanged, code: 59, flags: [])
        expect(recorder.quickFixes == 2)
    }

    private static func optionFlags(_ deviceMask: Int32) -> CGEventFlags {
        CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(deviceMask))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard condition() else {
            fatalError("Expectation failed at \(file):\(line)")
        }
    }
}

private final class Recorder: HotKeyDelegate {
    let startAllowed: Bool
    var starts = 0
    var finishes = 0
    var cancels = 0
    var quickFixes = 0

    func quickFixChord() { quickFixes += 1 }

    init(startAllowed: Bool = true) {
        self.startAllowed = startAllowed
    }

    func hotKeyDown() -> Bool {
        starts += 1
        return startAllowed
    }

    func hotKeyUp() {
        finishes += 1
    }

    func cancelDictation() {
        cancels += 1
    }
}
