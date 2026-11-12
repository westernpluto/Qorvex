import Foundation
import Security
import AuthenticationServices
import UIKit

/// Minimal Keychain storage for OAuth tokens.
enum Keychain {
    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.qorvex.reader",
         kSecAttrAccount as String: key]
    }

    static func set(_ value: String?, for key: String) {
        SecItemDelete(base(key) as CFDictionary)
        guard let value else { return }
        var q = base(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

struct OAuthTokens: Codable {
    var access: String
    var refresh: String?
    var expires: Date
}

/// Official Reddit OAuth ("installed app" flow) using the user's own client ID.
actor RedditAPIAuth {
    static let shared = RedditAPIAuth()
    private var tokens: OAuthTokens?

    init() {
        tokens = Keychain.get("oauth").flatMap { try? JSONDecoder().decode(OAuthTokens.self, from: Data($0.utf8)) }
    }

    var hasTokens: Bool { tokens != nil }

    private func save(_ t: OAuthTokens?) {
        tokens = t
        let s = t.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        Keychain.set(s, for: "oauth")
    }

    func signOut() { save(nil) }

    func accessToken(clientID: String, userAgent: String, forceRefresh: Bool = false) async throws -> String {
        guard let t = tokens else { throw RedditError.apiNotSignedIn }
        if !forceRefresh && t.expires > Date().addingTimeInterval(60) { return t.access }
        guard let refresh = t.refresh else { save(nil); throw RedditError.apiNotSignedIn }
        let new = try await tokenRequest(body: ["grant_type": "refresh_token", "refresh_token": refresh], clientID: clientID, userAgent: userAgent)
        save(new)
        return new.access
    }

    func exchange(code: String, clientID: String, redirectURI: String, userAgent: String) async throws {
        let t = try await tokenRequest(body: ["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI], clientID: clientID, userAgent: userAgent)
        save(t)
    }

    private func tokenRequest(body: [String: String], clientID: String, userAgent: String) async throws -> OAuthTokens {
        var req = URLRequest(url: URL(string: "https://www.reddit.com/api/v1/access_token")!)
        req.httpMethod = "POST"
        req.setValue("Basic " + Data("\(clientID):".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = Data(body.map { k, v in "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)" }.joined(separator: "&").utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        struct R: Decodable { let access_token: String?; let refresh_token: String?; let expires_in: Double?; let error: String? }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { throw RedditError.http(status) }
        guard status == 200, let access = r.access_token else {
            if r.error == "invalid_grant" { save(nil) }
            throw RedditError.apiAuthFailed(r.error ?? "HTTP \(status)")
        }
        return OAuthTokens(access: access, refresh: r.refresh_token ?? tokens?.refresh, expires: Date().addingTimeInterval(r.expires_in ?? 3600))
    }
}

/// Presents Reddit's official authorization page and completes sign-in.
@MainActor
final class RedditAPISignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = RedditAPISignIn()
    private var session: ASWebAuthenticationSession?

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? UIWindow()
        }
    }

    func signIn() async throws {
        let s = AppSettings.shared
        let clientID = s.apiClientID.trimmingCharacters(in: .whitespaces)
        let redirect = s.apiRedirectURI.trimmingCharacters(in: .whitespaces)
        guard !clientID.isEmpty else { throw RedditError.apiAuthFailed("Enter your Client ID first") }
        guard let redirectURL = URL(string: redirect), let scheme = redirectURL.scheme, !scheme.hasPrefix("http") else {
            throw RedditError.apiAuthFailed("The Redirect URI must use a custom scheme, e.g. qorvex://auth")
        }
        let state = UUID().uuidString
        var c = URLComponents(string: "https://www.reddit.com/api/v1/authorize.compact")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "duration", value: "permanent"),
            URLQueryItem(name: "scope", value: "identity read mysubreddits history"),
        ]
        guard let authURL = c.url else { throw RedditError.apiAuthFailed("Bad authorization URL") }

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let sess = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { url, error in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: error ?? RedditError.apiAuthFailed("Cancelled")) }
            }
            sess.presentationContextProvider = self
            sess.prefersEphemeralWebBrowserSession = false
            self.session = sess
            if !sess.start() { cont.resume(throwing: RedditError.apiAuthFailed("Couldn't open Reddit's sign-in page")) }
        }
        session = nil
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value { throw RedditError.apiAuthFailed(err) }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw RedditError.apiAuthFailed("Reddit didn't return an authorization code")
        }
        try await RedditAPIAuth.shared.exchange(code: code, clientID: clientID, redirectURI: redirect, userAgent: s.apiUserAgent)
        s.apiSignedIn = true
    }

    func signOut() async {
        await RedditAPIAuth.shared.signOut()
        AppSettings.shared.apiSignedIn = false
    }
}
