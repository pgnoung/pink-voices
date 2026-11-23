import Foundation
import Security
import LocalAuthentication

enum FinalReviewMode: String, CaseIterable {
    case local
    case openAI
}

enum FinalReviewModel: String, CaseIterable {
    case gpt6Luna = "gpt-6-luna"
    case gpt61Luna = "gpt-6.1-luna"
    case gpt61Terra = "gpt-6.1-terra"
    case gpt62Sol = "gpt-6.2-sol"

    var displayName: String { rawValue }
}

enum FinalReviewKeySource: String, CaseIterable {
    /// Default: the person's ChatGPT plan via "Sign in with ChatGPT".
    case chatGPT
    case personalKey

    var title: String {
        switch self {
        case .chatGPT: return "Sign in with ChatGPT (แนะนำ)"
        case .personalKey: return "OpenAI API key ของฉัน"
        }
    }
}

/// `models` is a list so a future explicit chain remains compatible. The UI
/// currently selects exactly one model per dictation.
struct FinalReviewConfiguration: Equatable {
    let mode: FinalReviewMode
    let models: [String]
    let keySource: FinalReviewKeySource
    var writingNote: String = ""

    var isOnline: Bool { mode == .openAI }
    var model: String? { models.first }
}

/// This is an account-verified allow-list. Requested models absent from it are
/// not selectable and can never be silently substituted.
enum FinalReviewCatalog {
    static let verifiedModels: [FinalReviewModel] = [.gpt61Terra, .gpt62Sol]
    /// Deliberately separate from account-verified models. The UI names it as
    /// legacy and only uses it when the person selects that exact item.
    static let explicitOptInModels: [FinalReviewModel] = [.gpt6Luna]
    static let selectableModels = verifiedModels + explicitOptInModels
    static let unavailableRequestedModels: [FinalReviewModel] = [.gpt61Luna]
}

/// A user's optional API key is isolated from the retired word-review item, so
/// a legacy opt-in cannot enable broader transcript review.
enum FinalReviewKeys {
    private static let service = "com.pngoung.pinkvoices.final-review"
    private static let account = "openai"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    static func key() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        let value = String(decoding: data, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    /// Resolves the source captured with a dictation. It has no dependency on
    /// mutable preferences, so a later settings change cannot alter a request.
    static func resolve(_ source: FinalReviewKeySource) -> String? {
        switch source {
        case .chatGPT: return nil // Resolved asynchronously through ChatGPTAccount.
        case .personalKey: return key()
        }
    }

    @discardableResult
    static func save(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 1024,
              value.utf8.allSatisfy({ (33...126).contains($0) }) else { return false }
        let data = Data(value.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

