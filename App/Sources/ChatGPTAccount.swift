import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Network
import Security

/// "Sign in with ChatGPT" (OpenAI's ChatGPT plan usage for locally run apps).
/// OAuth 2.0 authorization code + PKCE through the system browser and an IPv4
/// loopback callback. Tokens live only in this Mac's Keychain. The online word
/// check then calls the Responses API with the account's access token, so usage
/// comes from the person's ChatGPT plan instead of an API key bill.
/// Protocol per https://developers.openai.com/siwc (preview).
enum ChatGPTSignIn {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let sharingScope = "chatgpt.tokens.use.direct"
    static let preferredPort: UInt16 = 1455
    static let callbackPath = "/auth/callback"
    static let appName = Brand.name
    static let signInTimeout: TimeInterval = 300
}

enum ChatGPTAccountError: Error, Equatable {
    case discoveryFailed, portUnavailable, cancelled, timedOut, browserUnavailable
    case denied(String), registrationIncomplete, invalidTokenResponse, invalidIdentity
    case accountMismatch, sharingDisabled, network, storage

    var message: String {
        switch self {
        case .discoveryFailed: return "ยืนยันระบบล็อกอินของ OpenAI ไม่ได้ ลองใหม่อีกครั้ง"
        case .portUnavailable: return "พอร์ตสำหรับรับการล็อกอินถูกใช้อยู่ ปิดหน้าต่างล็อกอินเก่าแล้วลองใหม่"
        case .cancelled: return "ยกเลิกการล็อกอินแล้ว"
        case .timedOut: return "รอการล็อกอินนานเกินไป ลองกดล็อกอินใหม่"
        case .browserUnavailable: return "เปิดเบราว์เซอร์ไม่ได้"
        case .denied(let code): return "ChatGPT ไม่อนุญาตการเชื่อมต่อ (\(code))"
        case .registrationIncomplete: return "ChatGPT ยังลงทะเบียนแอปไม่เสร็จ ลองล็อกอินใหม่"
        case .invalidTokenResponse: return "ChatGPT ส่งข้อมูลล็อกอินไม่ครบ ลองใหม่อีกครั้ง"
        case .invalidIdentity: return "ยืนยันบัญชี ChatGPT ไม่ได้ ลองล็อกอินใหม่"
        case .accountMismatch: return "บัญชีที่ล็อกอินไม่ตรงกับบัญชีเดิม"
        case .sharingDisabled: return "บัญชีนี้ยังไม่เปิดให้แอปใช้โควตา ChatGPT"
        case .network: return "เชื่อมต่อ OpenAI ไม่ได้ ตรวจอินเทอร์เน็ตแล้วลองใหม่"
        case .storage: return "บันทึกการล็อกอินลง Keychain ไม่ได้"
        }
    }
}

struct ChatGPTConnection: Codable, Equatable {
    var clientId: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var earliestRefreshAt: Date?
    var subject: String
    var email: String?
    var name: String?
    var scopes: [String]

    var label: String { email ?? name ?? "บัญชี ChatGPT" }
}

/// Serializes sign-in and refresh so a rotated refresh token is never used twice.
actor ChatGPTAccount {
    static let shared = ChatGPTAccount()

    private var refreshTask: Task<String?, Never>?
    private var signInTask: Task<ChatGPTConnection, Error>?

    // MARK: Public

    /// Non-interactive read for UI labels.
    nonisolated static func current() -> ChatGPTConnection? { ChatGPTKeychain.load() }

    func signIn() async throws -> ChatGPTConnection {
        signInTask?.cancel()
        let task = Task { try await Self.authorize(previous: ChatGPTKeychain.load()) }
        signInTask = task
        defer { if signInTask == task { signInTask = nil } }
        let connection = try await task.value
        guard ChatGPTKeychain.save(connection) else { throw ChatGPTAccountError.storage }
        return connection
    }

    func cancelSignIn() { signInTask?.cancel() }

    /// A usable access token, refreshed when it expires within a minute. Nil means the
    /// dictation falls back to Local AI; it never opens a window during dictation.
    func accessToken() async -> String? {
        guard let connection = ChatGPTKeychain.load(), connection.scopes.contains(ChatGPTSignIn.sharingScope) else { return nil }
        if connection.expiresAt.timeIntervalSinceNow > 60 { return connection.accessToken }
        if let earliest = connection.earliestRefreshAt, earliest > Date() {
            return connection.expiresAt > Date() ? connection.accessToken : nil
        }
        if let refreshTask { return await refreshTask.value }
        let task = Task { await Self.refresh(connection) }
        refreshTask = task
        let token = await task.value
        refreshTask = nil
        return token
    }

    func signOut() async {
        guard let connection = ChatGPTKeychain.load() else { return }
        ChatGPTKeychain.delete()
        await Self.revoke(connection)
    }

    // MARK: Authorization

    private struct Discovery { let authorization: URL; let token: URL; let revocation: URL? }

    private static func discovery() async throws -> Discovery {
        guard let url = URL(string: ChatGPTSignIn.issuer + "/.well-known/openid-configuration"),
              let (data, response) = try? await ChatGPTHTTP.session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["issuer"] as? String == ChatGPTSignIn.issuer,
              let authorization = sameOrigin(json["authorization_endpoint"]),
              let token = sameOrigin(json["token_endpoint"]) else { throw ChatGPTAccountError.discoveryFailed }
        return Discovery(authorization: authorization, token: token, revocation: sameOrigin(json["revocation_endpoint"]))
    }

    private static func sameOrigin(_ value: Any?) -> URL? {
        guard let text = value as? String, let url = URL(string: text), url.scheme == "https",
              url.host == URL(string: ChatGPTSignIn.issuer)?.host else { return nil }
        return url
    }

    private static func authorize(previous: ChatGPTConnection?) async throws -> ChatGPTConnection {
        let state = randomValue(), nonce = randomValue(), verifier = randomValue()
        let provider = try await discovery()
        let savedClient = ChatGPTClientRegistration.clientId
        let listener = try await LoopbackListener.start(preferredPort: ChatGPTSignIn.preferredPort, state: state)
        defer { listener.stop() }
        let redirect = "http://127.0.0.1:\(listener.port)\(ChatGPTSignIn.callbackPath)"

        var components = URLComponents(url: provider.authorization, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: savedClient ?? "dynamic_agent_client"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: ChatGPTSignIn.scopes),
            URLQueryItem(name: "resource", value: ChatGPTSignIn.resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
        ]
        if savedClient == nil { items.append(URLQueryItem(name: "agent_name_hint", value: ChatGPTSignIn.appName)) }
        if let email = previous?.email { items.append(URLQueryItem(name: "login_hint", value: email)) }
        components.queryItems = items
        // `+` would be read as a space in form-style query parsing.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw ChatGPTAccountError.discoveryFailed }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw ChatGPTAccountError.browserUnavailable }

        let callback = try await listener.waitForCallback(timeout: ChatGPTSignIn.signInTimeout)
        if let error = callback.error { throw ChatGPTAccountError.denied(error) }
        let clientId = callback.clientId ?? savedClient
        guard let code = callback.code, let clientId, clientId != "dynamic_agent_client",
              clientId.range(of: #"^[A-Za-z0-9_-]{1,200}$"#, options: .regularExpression) != nil,
              savedClient == nil || callback.clientId == nil || callback.clientId == savedClient
        else { throw ChatGPTAccountError.registrationIncomplete }
        // Keep the issued registration even if the one-time code exchange fails.
        ChatGPTClientRegistration.clientId = clientId

        let data = try await tokenRequest(provider.token, [
            "grant_type": "authorization_code", "client_id": clientId, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect, "resource": ChatGPTSignIn.resource
        ])
        guard let idToken = data["id_token"] as? String,
              let identity = verifiedIdentity(idToken, clientId: clientId, nonce: nonce) else { throw ChatGPTAccountError.invalidIdentity }
        if let previous, previous.subject != identity.subject { throw ChatGPTAccountError.accountMismatch }
        let connection = try connection(from: data, clientId: clientId, identity: identity, previousRefresh: nil)
        guard connection.scopes.contains(ChatGPTSignIn.sharingScope) else { throw ChatGPTAccountError.sharingDisabled }
        return connection
    }

    private static func refresh(_ previous: ChatGPTConnection) async -> String? {
        guard let provider = try? await discovery() else {
            return previous.expiresAt > Date() ? previous.accessToken : nil
        }
        do {
            let data = try await tokenRequest(provider.token, [
                "grant_type": "refresh_token", "client_id": previous.clientId,
                "refresh_token": previous.refreshToken, "resource": ChatGPTSignIn.resource
            ])
            var identity = (subject: previous.subject, email: previous.email, name: previous.name)
            if let idToken = data["id_token"] as? String {
                guard let verified = verifiedIdentity(idToken, clientId: previous.clientId, nonce: nil),
                      verified.subject == previous.subject else { ChatGPTKeychain.delete(); return nil }
                identity = verified
            }
            var fields = data
            if fields["scope"] == nil { fields["scope"] = previous.scopes.joined(separator: " ") }
            let next = try connection(from: fields, clientId: previous.clientId, identity: identity, previousRefresh: previous.refreshToken)
            // Rotation consumed the old refresh token: persist before anything else can fail.
            guard ChatGPTKeychain.save(next) else { return nil }
            return next.accessToken
        } catch ChatGPTAccountError.denied(let code) where ["invalid_grant", "invalid_client", "unauthorized_client"].contains(code) {
            ChatGPTKeychain.delete()
            return nil
        } catch {
            return previous.expiresAt > Date() ? previous.accessToken : nil
        }
    }

    private static func revoke(_ connection: ChatGPTConnection) async {
        guard let provider = try? await discovery(), let endpoint = provider.revocation else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(["token": connection.refreshToken, "token_type_hint": "refresh_token", "client_id": connection.clientId])
        _ = try? await ChatGPTHTTP.session.data(for: request)
    }

    private static func tokenRequest(_ endpoint: URL, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form(fields)
        guard let (data, response) = try? await ChatGPTHTTP.session.data(for: request),
              let http = response as? HTTPURLResponse else { throw ChatGPTAccountError.network }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            throw ChatGPTAccountError.denied((json?["error"] as? String) ?? "HTTP \(http.statusCode)")
        }
        guard let json else { throw ChatGPTAccountError.invalidTokenResponse }
        return json
    }

    private static func connection(from data: [String: Any], clientId: String,
                                   identity: (subject: String, email: String?, name: String?),
                                   previousRefresh: String?) throws -> ChatGPTConnection {
        guard let access = data["access_token"] as? String, !access.isEmpty,
              (data["token_type"] as? String)?.lowercased() == "bearer",
              let expires = (data["expires_in"] as? NSNumber)?.doubleValue, expires > 0,
              let refresh = (data["refresh_token"] as? String) ?? previousRefresh, !refresh.isEmpty,
              let scope = data["scope"] as? String else { throw ChatGPTAccountError.invalidTokenResponse }
        return ChatGPTConnection(clientId: clientId, accessToken: access, refreshToken: refresh,
                                 expiresAt: Date().addingTimeInterval(expires),
                                 earliestRefreshAt: earliestRefresh(data["earliest_refresh_at"]),
                                 subject: identity.subject, email: identity.email, name: identity.name,
                                 scopes: scope.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    private static func earliestRefresh(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        if let text = value as? String { return ISO8601DateFormatter().date(from: text) }
        return nil
    }

    /// The ID token arrives directly from the token endpoint over TLS, which OpenID Connect
    /// accepts in place of a signature check; the claims are still validated here.
    static func verifiedIdentity(_ token: String, clientId: String, nonce: String?) -> (subject: String, email: String?, name: String?)? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = base64URLDecode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              claims["iss"] as? String == ChatGPTSignIn.issuer,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let expiry = (claims["exp"] as? NSNumber)?.doubleValue else { return nil }
        let audience: [String] = (claims["aud"] as? [String]) ?? [(claims["aud"] as? String) ?? ""]
        guard audience.contains(clientId) else { return nil }
        if audience.count > 1 || claims["azp"] != nil { guard claims["azp"] as? String == clientId else { return nil } }
        if let nonce {
            guard claims["nonce"] as? String == nonce, expiry + 5 > Date().timeIntervalSince1970 else { return nil }
        }
        return (subject, claims["email"] as? String, claims["name"] as? String)
    }

    // MARK: Encoding helpers

    static func randomValue() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return Data(base64Encoded: value)
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
    }
}

enum ChatGPTHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()
}

/// The issued OAuth client ID is not a secret; reusing it avoids registering the app again.
enum ChatGPTClientRegistration {
    private static let key = "chatGPTClientId"
    static var clientId: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum ChatGPTKeychain {
    private static let service = "com.pngoung.pinkvoices.chatgpt"
    private static let account = "connection"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    static func load() -> ChatGPTConnection? {
        var request = query
        request[kSecReturnData as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ChatGPTConnection.self, from: data)
    }

    static func save(_ connection: ChatGPTConnection) -> Bool {
        guard let data = try? JSONEncoder().encode(connection) else { return false }
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}

/// One-shot HTTP listener on 127.0.0.1 for the OAuth redirect. It answers only
/// GET /auth/callback with the matching state and Host header.
final class LoopbackListener {
    struct Callback { let code: String?; let clientId: String?; let error: String? }

    let port: UInt16
    private let listener: NWListener
    private let state: String
    private let queue = DispatchQueue(label: "pinkvoices.chatgpt.callback")
    private var continuation: CheckedContinuation<Callback, Error>?
    private var pending: Result<Callback, Error>?

    private init(listener: NWListener, port: UInt16, state: String) {
        self.listener = listener
        self.port = port
        self.state = state
    }

    static func start(preferredPort: UInt16, state: String) async throws -> LoopbackListener {
        for candidate in [preferredPort, 0] {
            if let listener = try? await bind(candidate, state: state) { return listener }
        }
        throw ChatGPTAccountError.portUnavailable
    }

    private static func bind(_ port: UInt16, state: String) async throws -> LoopbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = false
        let raw = try NWListener(using: parameters)
        let ready: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            raw.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; continuation.resume(returning: raw.port?.rawValue ?? port)
                case .failed, .cancelled: resumed = true; continuation.resume(throwing: ChatGPTAccountError.portUnavailable)
                default: break
                }
            }
            raw.newConnectionHandler = { _ in }
            raw.start(queue: DispatchQueue(label: "pinkvoices.chatgpt.bind"))
        }
        let listener = LoopbackListener(listener: raw, port: ready, state: state)
        raw.newConnectionHandler = { [weak listener] connection in listener?.accept(connection) }
        return listener
    }

    func waitForCallback(timeout: TimeInterval) async throws -> Callback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Callback, Error>) in
                queue.async {
                    if let pending = self.pending { continuation.resume(with: pending); return }
                    self.continuation = continuation
                    self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(ChatGPTAccountError.timedOut)) }
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(ChatGPTAccountError.cancelled)) }
        }
    }

    func stop() { listener.cancel() }

    private func finish(_ result: Result<Callback, Error>) {
        guard pending == nil else { return }
        pending = result
        continuation?.resume(with: result)
        continuation = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let (status, body) = self.handle(request)
            let html = Data(body.utf8)
            var head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.count)\r\n"
            head += "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
            head += "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + html, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func handle(_ request: String) -> (String, String) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let host = lines.first { $0.lowercased().hasPrefix("host:") }?.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard parts.count >= 2, parts[0] == "GET", host == "127.0.0.1:\(port)", pending == nil,
              let components = URLComponents(string: "http://127.0.0.1:\(port)" + parts[1]),
              components.path == ChatGPTSignIn.callbackPath else { return ("404 Not Found", page("ไม่พบหน้านี้", "")) }
        let items = components.queryItems ?? []
        func one(_ name: String) -> String?? {
            let values = items.filter { $0.name == name }.compactMap(\.value)
            return values.count > 1 ? .some(nil) : values.first.map { .some($0) } ?? .none
        }
        guard case .some(.some(let returnedState)) = one("state"), returnedState == state else {
            return ("400 Bad Request", page("ล็อกอินไม่ตรงกับคำขอ", "กลับไปที่แท็บที่เริ่มล็อกอินจาก \(Brand.name)"))
        }
        if case .some(.some(let error)) = one("error") {
            finish(.success(Callback(code: nil, clientId: nil, error: error)))
            return ("200 OK", page("ยังไม่ได้เชื่อม ChatGPT", "กลับไปที่ \(Brand.name) แล้วลองใหม่ได้เลย"))
        }
        guard case .some(.some(let code)) = one("code") else {
            finish(.failure(ChatGPTAccountError.registrationIncomplete))
            return ("400 Bad Request", page("ล็อกอินไม่สมบูรณ์", "กลับไปที่ \(Brand.name) แล้วลองใหม่"))
        }
        let client: String?
        switch one("client_id") {
        case .some(.some(let value)): client = value
        case .some(.none): finish(.failure(ChatGPTAccountError.registrationIncomplete)); return ("400 Bad Request", page("ล็อกอินไม่สมบูรณ์", ""))
        case .none: client = nil
        }
        finish(.success(Callback(code: code, clientId: client, error: nil)))
        return ("200 OK", page("เชื่อม ChatGPT แล้ว", "กลับไปที่ \(Brand.name) ได้เลย ปิดแท็บนี้ได้"))
    }

    private func page(_ title: String, _ body: String) -> String {
        """
        <!doctype html><html lang="th"><meta charset="utf-8"><title>\(Brand.name)</title>
        <style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:radial-gradient(circle at 20% 10%,#5a1f4a,#1c1828 55%,#120a1c);color:#fff;font:17px -apple-system,system-ui}main{max-width:30rem;padding:40px;border-radius:28px;background:#2b1838cc;border:1px solid #f391a955;box-shadow:0 30px 80px #0008}h1{margin:0 0 10px;font-size:28px;background:linear-gradient(90deg,#ffe3ef,#ff4fa3,#ffb38a);-webkit-background-clip:text;color:transparent}p{color:#f6d3e0;margin:0}</style>
        <main><h1>\(title)</h1><p>\(body)</p></main></html>
        """
    }
}
