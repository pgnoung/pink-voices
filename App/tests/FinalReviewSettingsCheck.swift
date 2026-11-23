import Foundation

@main struct FinalReviewSettingsCheck {
    static func main() {
        let domain = "com.pngoung.pinkvoices.final-review-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }

        let review = WordReviewController(defaults: defaults)
        expect(review.finalReviewConfiguration.mode == .local, "new install is local")
        defaults.set("jevLuna", forKey: "optionalWordReviewer")
        expect(review.finalReviewConfiguration.mode == .local, "legacy word-review opt-in never migrates to transcript review")
        defaults.set("openAI", forKey: "finalReviewMode")
        defaults.set("gpt-6.1-luna", forKey: "finalReviewModel")
        expect(review.finalReviewConfiguration.mode == .local, "unavailable requested model does not migrate online")

        defaults.set("gpt-6.2-sol", forKey: "finalReviewModel")
        expect(review.finalReviewConfiguration.keySource == .chatGPT, "Sign in with ChatGPT is the default connection")
        defaults.set("personalKey", forKey: "finalReviewKeySource")
        defaults.set("  คงคำลงท้าย  ", forKey: "dictationWritingNote")
        let online = review.finalReviewConfiguration
        expect(online.writingNote == "คงคำลงท้าย", "persisted guidance applies to the chosen online reviewer")
        expect(online.mode == .openAI && online.models == ["gpt-6.2-sol"] && online.keySource == .personalKey, "persists exact verified selection")
        expect(FinalReviewCatalog.verifiedModels.map(\.rawValue) == ["gpt-6.1-terra", "gpt-6.2-sol"], "verified selector list")
        expect(FinalReviewCatalog.selectableModels.map(\.rawValue) == ["gpt-6.1-terra", "gpt-6.2-sol", "gpt-6-luna"], "legacy luna requires its explicit item")
        expect(!FinalReviewCatalog.selectableModels.contains(.gpt61Luna), "unavailable luna is never selectable")
        print("FinalReviewSettingsCheck passed")
    }

    static func expect(_ value: Bool, _ message: String) {
        if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
