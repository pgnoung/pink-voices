import AppKit

@main struct PinkHUDCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let hud = PinkVoiceHUD()
        let first = UUID()
        let second = UUID()
        hud.show(.recording, session: first)
        guard let panel = app.windows.compactMap({ $0 as? NSPanel }).first(where: { $0.isVisible }),
              let view = panel.contentView else { fatalError("HUD did not present its panel") }
        precondition(panel.styleMask.contains(.nonactivatingPanel) && panel.ignoresMouseEvents && !panel.isKeyWindow)
        precondition(view.accessibilityLabel()?.contains("กำลังฟัง") == true)
        for level: CGFloat in [0, 0.15, 0.7, 0.05, 1, 0] { hud.setLevel(level, session: first) }
        hud.show(.finishing, session: first)
        precondition(view.accessibilityLabel()?.contains("กำลังเรียบเรียง") == true)
        hud.transition(to: .checking, session: first)
        precondition(view.accessibilityLabel()?.contains("AI กำลังตรวจคำ") == true)
        hud.transition(to: .localFallback, session: first)
        precondition(view.accessibilityLabel()?.contains("Local AI") == true)
        hud.finish(.inserted, session: first, hideAfter: 0.05)
        hud.show(.recording, session: second)
        hud.finish(.failed, session: first, hideAfter: 0.01)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(panel.isVisible && view.accessibilityLabel()?.contains("กำลังฟัง") == true)
        hud.finish(.cancelled, session: second, hideAfter: 0.03)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        precondition(!panel.isVisible && !panel.isKeyWindow)
        precondition(front == NSWorkspace.shared.frontmostApplication?.processIdentifier, "foreground changed during HUD test")
        print("HUD: visible nonactivating click-through native window, state labels, stale-session guard, foreground retained, dismissed")
    }
}
