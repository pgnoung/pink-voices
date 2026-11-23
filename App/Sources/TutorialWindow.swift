import AppKit
import WebKit

/// Short how-to video: a page on the product site (Info.plist PVTutorialVideoURL) that plays it through a signed,
/// expiring Bunny Stream embed, so no downloadable MP4 exists anywhere.
/// Hidden in builds that do not set it.
final class TutorialWindow: NSObject, NSWindowDelegate {
    private static var current: TutorialWindow?
    private let window: NSWindow
    private let web: WKWebView
    private let note = StudioText.label("", PinkTheme.rounded(12, .medium), PinkTheme.textSecondary)

    static var isAvailable: Bool { Brand.tutorialVideoURL != nil }

    static func show() {
        guard let url = Brand.tutorialVideoURL else { return }
        if let current { current.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let sheet = TutorialWindow(url: url)
        current = sheet
        NSApp.activate(ignoringOtherApps: true)
        sheet.window.center()
        sheet.window.makeKeyAndOrderFront(nil)
    }

    private init(url: URL) {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "วิธีใช้ \(Brand.name)"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 640, height: 440)
        PinkTheme.style(window)
        build()
    }

    private func build() {
        let backdrop = StudioBackdrop()
        window.contentView = backdrop
        let video = web
        note.stringValue = "ต้องต่ออินเทอร์เน็ต"
        video.wantsLayer = true
        video.layer?.cornerRadius = 16
        video.layer?.masksToBounds = true
        let title = StudioText.label("ดูวิธีใช้ใน 40 วินาที", PinkTheme.rounded(20, .heavy))
        var buttons: [NSView] = [note, NSView()]
        if let page = Brand.tutorialPageURL {
            buttons.append(PinkButton("ดูวิธีติดตั้งแบบเต็มบนเว็บ", symbol: "safari") { NSWorkspace.shared.open(page) })
        }
        buttons.append(PinkButton("ปิด", style: .primary) { [weak self] in self?.window.close() })
        let bar = NSStackView(views: buttons)
        bar.spacing = 10
        for view in [title, video, bar] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; backdrop.addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 24),
            title.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 34),
            video.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 20),
            video.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -20),
            video.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            video.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -14),
            bar.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 24),
            bar.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -18)
        ])
    }

    func windowWillClose(_ notification: Notification) {
        web.loadHTMLString("", baseURL: nil)
        if TutorialWindow.current === self { TutorialWindow.current = nil }
    }
}
