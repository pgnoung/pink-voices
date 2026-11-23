import AppKit

/// Product identity read from Info.plist, so the open-source code carries no brand of its own.
/// The official Pink voices build sets the name, credit, source link and family links there.
enum Brand {
    private static func value(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }

    static let name = (value("CFBundleDisplayName") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Voices"
    /// Optional footer credit, e.g. "made with ♥ by pngoung"; the heart is tinted.
    static let credit = value("PVCredit") as? String
    static let sourceURL = (value("PVSourceURL") as? String).flatMap(URL.init(string:))
    /// Short how-to video streamed in the app, and the full tutorial page on the web.
    static let tutorialVideoURL = (value("PVTutorialVideoURL") as? String).flatMap(URL.init(string:))
    static let tutorialPageURL = (value("PVTutorialPageURL") as? String).flatMap(URL.init(string:))

    struct FamilyApp { let name: String; let tagline: String; let url: URL; let symbol: String }
    /// Sister apps shown as cards in Studio. Empty in a plain open-source build.
    static let family: [FamilyApp] = (value("PVFamily") as? [[String: String]] ?? []).compactMap { item in
        guard let name = item["name"], let link = item["url"], let url = URL(string: link), url.scheme == "https" else { return nil }
        return FamilyApp(name: name, tagline: item["tagline"] ?? "", url: url, symbol: item["symbol"] ?? "sparkles")
    }
}
