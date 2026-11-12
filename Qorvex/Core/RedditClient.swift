import Foundation
import Observation

enum RedditError: LocalizedError {
    case offline, rateLimited, notFound, privateCommunity, banned, quarantined, blocked(Int), loginRequired, apiNotSignedIn, apiAuthFailed(String), http(Int), decoding

    var errorDescription: String? {
        switch self {
        case .offline: return "You're offline"
        case .rateLimited: return "Reddit asked us to slow down for a moment"
        case .notFound: return "Not found"
        case .loginRequired: return "Reddit now requires signing in"
        case .apiNotSignedIn: return "Sign in with your Reddit API key in Settings"
        case .apiAuthFailed(let m): return "Reddit API sign-in failed: \(m)"
        case .privateCommunity: return "This community is private"
        case .banned: return "This community has been banned"
        case .quarantined: return "This community is quarantined"
        case .blocked(let c):
            if c == 200 { return "Reddit sent a web page instead of data" }
            if (300..<400).contains(c) { return "Reddit redirected the request away (HTTP \(c))" }
            return "Reddit blocked the request (HTTP \(c))"
        case .http(let c): return "Reddit returned an error (\(c))"
        case .decoding: return "Couldn't read Reddit's response"
        }
    }
}

struct Fetched<T> {
    let value: T
    let fromCache: Bool
    let stale: Bool
    let age: TimeInterval
    let error: Error?
}

enum CacheKind { case list, post, about
    var ttl: TimeInterval {
        let m = AppSettings.shared.cacheMode
        switch self {
        case .list: return m.listTTL
        case .post: return m.postTTL
        case .about: return m == .saver ? 7 * 86400 : 86400
        }
    }
}

/// Live numbers for the Settings screen and the "pacing" indicator.
@MainActor @Observable
final class NetworkStatus {
    static let shared = NetworkStatus()
    var waiting = 0
    var totalRequests = 0
    var cacheHits = 0
    var recent: [Date] = []
    var lastError: String?
    var blocked = false
    var loginRequired = false
    // Restored from the last launch so Home loads your own feed from the first frame.
    var signedIn = UserDefaults.standard.bool(forKey: "qx.signedIn")
    var username: String? = UserDefaults.standard.string(forKey: "qx.username")
    var usingBrowserEngine = false
    var backoffUntil: Date?

    var log: [RequestLog] = []

    var usedThisMinute: Int { recent.filter { Date().timeIntervalSince($0) < 60 }.count }

    func record(_ entry: RequestLog) {
        log.insert(entry, at: 0)
        if log.count > 25 { log.removeLast() }
    }

    var logText: String {
        log.map { e in
            var line = "\(e.date.formatted(date: .omitted, time: .standard)) [\(e.via)] \(e.status) \(e.contentType)\n  \(e.url)"
            if let l = e.location { line += "\n  → \(l)" }
            if !e.snippet.isEmpty { line += "\n  \(e.snippet)" }
            return line
        }.joined(separator: "\n\n")
    }
}

struct RequestLog: Identifiable {
    let id = UUID()
    let date = Date()
    let via: String
    let url: String
    let status: Int
    let contentType: String
    let location: String?
    let snippet: String
}

/// Stops URLSession from silently following redirects so we can see where Reddit sends us.
final class RedirectCatcher: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Reads Reddit's public JSON pages straight from the phone — no API key, no OAuth, no server.
/// A self-imposed request budget keeps every request under Reddit's anonymous limit, and a
/// persistent on-disk cache means most navigation costs no request at all.
actor RedditClient {
    static let shared = RedditClient()

    private var stamps: [Date] = []
    private var backoffUntil = Date.distantPast
    private var inflight: [String: Task<Data, Error>] = [:]
    private var memory: [String: (date: Date, data: Data)] = [:]
    private var memoryOrder: [String] = []
    private let session: URLSession
    private let cacheDir: URL
    private var preferBrowser = false
    private var loginWallUntil = Date.distantPast
    private var userAgent: String?

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.httpAdditionalHeaders = ["Accept": "application/json", "Accept-Language": Locale.preferredLanguages.prefix(3).joined(separator: ", ")]
        cfg.httpCookieStorage = .shared
        cfg.httpShouldSetCookies = true
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("reddit", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Rate governor

    private func acquireSlot() async throws {
        var counted = false
        defer { if counted { Task { @MainActor in NetworkStatus.shared.waiting -= 1 } } }
        while true {
            try Task.checkCancellation()
            let now = Date()
            if now < backoffUntil {
                if !counted { counted = true; await MainActor.run { NetworkStatus.shared.waiting += 1 } }
                try await Task.sleep(nanoseconds: UInt64(backoffUntil.timeIntervalSince(now) * 1e9))
                continue
            }
            stamps.removeAll { now.timeIntervalSince($0) >= 60 }
            let budget = max(1, await MainActor.run { AppSettings.shared.apiActive ? max(60, AppSettings.shared.requestsPerMinute) : (AppSettings.shared.sessionRouteActive ? max(20, AppSettings.shared.requestsPerMinute) : AppSettings.shared.requestsPerMinute) })
            if stamps.count < budget {
                stamps.append(now)
                await MainActor.run {
                    let s = NetworkStatus.shared
                    s.totalRequests += 1
                    s.recent.append(now)
                    s.recent.removeAll { now.timeIntervalSince($0) >= 60 }
                }
                return
            }
            if !counted { counted = true; await MainActor.run { NetworkStatus.shared.waiting += 1 } }
            let wait = 60 - now.timeIntervalSince(stamps[0]) + 0.05
            try await Task.sleep(nanoseconds: UInt64(max(0.1, wait) * 1e9))
        }
    }

    // MARK: - Cache

    private func fileURL(_ key: String) -> URL {
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return cacheDir.appendingPathComponent(String(h, radix: 16) + ".json")
    }

    private func cached(_ key: String) -> (date: Date, data: Data)? {
        if let m = memory[key] { return m }
        let url = fileURL(key)
        guard let data = try? Data(contentsOf: url),
              let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        remember(key, date, data)
        return (date, data)
    }

    private func remember(_ key: String, _ date: Date, _ data: Data) {
        memory[key] = (date, data)
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
        if memoryOrder.count > 80 { memory.removeValue(forKey: memoryOrder.removeFirst()) }
    }

    private func store(_ key: String, _ data: Data) {
        remember(key, Date(), data)
        let url = fileURL(key)
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }

    func clearLoginWall() { loginWallUntil = .distantPast }

    func clearCache() {
        memory = [:]; memoryOrder = []
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func cacheStats() -> (files: Int, bytes: Int) {
        let items = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = items.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return (items.count, bytes)
    }

    func prune(olderThan age: TimeInterval = 4 * 86400) {
        let items = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for u in items {
            if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(d) > age {
                try? FileManager.default.removeItem(at: u)
            }
        }
    }

    // MARK: - Fetch

    private func download(_ path: String, host: String) async throws -> Data {
        let (useAPI, useSession, hasAccount) = await MainActor.run { (AppSettings.shared.apiActive, AppSettings.shared.sessionRouteActive, AppSettings.shared.webSessionSignedIn) }
        // A Reddit account is required: signed out, nothing is sent to Reddit at all.
        guard useAPI || hasAccount else { throw RedditError.loginRequired }
        if useAPI {
            try await acquireSlot()
            return try await viaAPI(path)
        }
        if useSession {
            try await acquireSlot()
            do {
                let data = try await viaSession(path)
                await setState(blocked: false, login: false)
                return data
            } catch RedditError.loginRequired {
                await setState(blocked: false, login: true)
                throw RedditError.loginRequired
            } catch RedditError.blocked(let code) {
                // Fall through to the limited web route below for what it can still serve.
                if !Self.webServes(path) { await setState(blocked: true, login: false); throw RedditError.blocked(code) }
            }
        }
        let mode = await MainActor.run { AppSettings.shared.connection }
        let sep = path.contains("?") ? "&" : "?"
        guard let url = URL(string: host + Self.pageStyle(path) + sep + "raw_json=1") else { throw RedditError.notFound }
        let signedIn = await MainActor.run { NetworkStatus.shared.signedIn }
        // Signed in: go straight to the browser engine, which carries the session like Safari.
        let browserFirst = mode == .browser || (mode == .automatic && (preferBrowser || signedIn))
        // After hitting the login wall, don't keep knocking: fail fast for a couple of minutes.
        if Date() < loginWallUntil { throw RedditError.loginRequired }
        do {
            try await acquireSlot()
            let data = browserFirst ? try await viaBrowser(url) : try await viaDirect(url)
            await setState(blocked: false, login: false)
            return data
        } catch RedditError.loginRequired {
            // Direct requests carry synced cookies, but the browser engine holds the freshest
            // session; give it one try before asking the user to sign in.
            if mode == .automatic && !browserFirst {
                preferBrowser = true
                do {
                    try await acquireSlot()
                    let data = try await viaBrowser(url)
                    await setState(blocked: false, login: false)
                    return data
                } catch RedditError.loginRequired { } catch RedditError.blocked { }
            }
            loginWallUntil = Date().addingTimeInterval(120)
            await setState(blocked: false, login: true)
            throw RedditError.loginRequired
        } catch RedditError.blocked(let code) {
            guard mode == .automatic else { await setState(blocked: true, login: false); throw RedditError.blocked(code) }
            if !browserFirst {
                preferBrowser = true
                await MainActor.run { NetworkStatus.shared.usingBrowserEngine = true }
                do {
                    try await acquireSlot()
                    let data = try await viaBrowser(url)
                    await setState(blocked: false, login: false)
                    return data
                } catch RedditError.loginRequired {
                    loginWallUntil = Date().addingTimeInterval(120)
                    await setState(blocked: false, login: true)
                    throw RedditError.loginRequired
                } catch RedditError.blocked { }
            }
            await setState(blocked: true, login: false)
            throw RedditError.blocked(code)
        }
    }

    /// Reddit serves `.json` appended to a page URL (`/r/pics/.json`, `/r/pics/new/.json`), the way
    /// you'd add it in Safari, but blocks the bare `/r/pics/hot.json` form. Rewrite every path to
    /// the page style: `/a/b.json?x` → `/a/b/.json?x`.
    static func pageStyle(_ path: String) -> String {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var p = String(parts[0])
        if p.hasSuffix(".json") && !p.hasSuffix("/.json") {
            p = String(p.dropLast(5)) + "/.json"
        }
        return parts.count > 1 ? p + "?" + parts[1] : p
    }

    private func setState(blocked: Bool, login: Bool) async {
        await MainActor.run {
            let s = NetworkStatus.shared
            if s.blocked != blocked { s.blocked = blocked }
            if s.loginRequired != login { s.loginRequired = login }
        }
    }

    private func setBlocked(_ b: Bool) async {
        await MainActor.run { if NetworkStatus.shared.blocked != b { NetworkStatus.shared.blocked = b } }
    }

    private let redirectCatcher = RedirectCatcher()

    private func log(_ via: String, _ url: URL, _ status: Int, _ ct: String, _ location: String?, _ data: Data) async {
        let snippet = String(decoding: data.prefix(160), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let entry = RequestLog(via: via, url: url.absoluteString, status: status, contentType: ct, location: location,
                               snippet: ct.contains("json") && (200..<300).contains(status) && !url.path.hasPrefix("/api/morechildren") ? "" : snippet)
        await MainActor.run { NetworkStatus.shared.record(entry) }
    }

    /// Reddit sends signed-out JSON requests to /login (old) or to the front page (www).
    private static func isLoginWall(_ u: URL) -> Bool {
        u.path.hasPrefix("/login") || u.path.hasPrefix("/account/login") || u.path == "/" || u.path.isEmpty
    }

    private static func isJSONResource(_ u: URL) -> Bool {
        guard let host = u.host?.lowercased(), host == "reddit.com" || host.hasSuffix(".reddit.com") else { return false }
        return u.path.hasSuffix(".json")
    }

    private func viaDirect(_ start: URL) async throws -> Data {
        if userAgent == nil { userAgent = await MainActor.run { WebTransport.safariUserAgent } }
        var url = start
        for _ in 0..<3 {
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: req, delegate: redirectCatcher)
            } catch let e as URLError where [URLError.Code.notConnectedToInternet, URLError.Code.networkConnectionLost, URLError.Code.dataNotAllowed].contains(e.code) {
                throw RedditError.offline
            }
            guard let http = response as? HTTPURLResponse else { throw RedditError.http(0) }
            let ct = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            let location = http.value(forHTTPHeaderField: "Location")
            await log("direct", url, http.statusCode, ct, location, data)
            if (300..<400).contains(http.statusCode) {
                // Follow only if Reddit points at the same JSON resource (e.g. another host);
                // anything else (login, interstitial, HTML page) means the request was filtered.
                if let location, let next = URL(string: location, relativeTo: url)?.absoluteURL {
                    if Self.isJSONResource(next) { url = next; continue }
                    if Self.isLoginWall(next) { throw RedditError.loginRequired }
                }
                throw RedditError.blocked(http.statusCode)
            }
            return try await interpret(status: http.statusCode, contentType: ct, retryAfter: http.value(forHTTPHeaderField: "Retry-After"), data: data)
        }
        throw RedditError.blocked(310)
    }

    // MARK: Key-free web session route (cookie auth on oauth.reddit.com)

    private var sessionStreak = 0
    private var modhash: String?
    private var sessionCooldownLevel = 0

    /// oauth.reddit.com takes listings with `.json`, but `/api/*` endpoints without it.
    static func oauthPath(_ path: String) -> String {
        guard path.hasPrefix("/api/") else { return path }
        return path.replacingOccurrences(of: ".json?", with: "?").replacingOccurrences(of: ".json", with: "")
    }

    /// What the plain web route still serves (front pages of single communities, r/popular,
    /// post pages, profiles) — used as a fallback when the session route is blocked.
    static func webServes(_ path: String) -> Bool {
        let p = path.split(separator: "?").first.map(String.init) ?? path
        if p.hasPrefix("/api/") || p.contains("/search") || p.contains("+") { return false }
        for sort in ["/new.json", "/top.json", "/rising.json", "/controversial.json", "/hot.json", "/best.json"] where p.hasSuffix(sort) { return false }
        return true
    }

    private func viaSession(_ path: String) async throws -> Data {
        let cookie = await RedditAccount.cookieHeader()
        guard cookie.contains("reddit_session=") else { throw RedditError.loginRequired }
        if userAgent == nil { userAgent = await MainActor.run { WebTransport.safariUserAgent } }
        let p = Self.oauthPath(path)
        let sep = p.contains("?") ? "&" : "?"
        guard let url = URL(string: "https://oauth.reddit.com" + p + sep + "raw_json=1") else { throw RedditError.notFound }
        var req = URLRequest(url: url)
        req.httpShouldHandleCookies = false
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req, delegate: redirectCatcher)
        } catch let e as URLError where [URLError.Code.notConnectedToInternet, URLError.Code.networkConnectionLost, URLError.Code.dataNotAllowed].contains(e.code) {
            throw RedditError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw RedditError.http(0) }
        let ct = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let location = http.value(forHTTPHeaderField: "Location")
        await log("session", url, http.statusCode, ct, location, data)
        if (300..<400).contains(http.statusCode) {
            if let location, let next = URL(string: location, relativeTo: url)?.absoluteURL, Self.isLoginWall(next) { throw RedditError.loginRequired }
            await sessionBlocked()
            throw RedditError.blocked(http.statusCode)
        }
        do {
            let d = try await interpret(status: http.statusCode, contentType: ct, retryAfter: http.value(forHTTPHeaderField: "Retry-After"), data: data)
            sessionStreak = 0
            sessionCooldownLevel = 0
            return d
        } catch RedditError.blocked(let c) {
            // A 404 "page not found" means this route doesn't serve that path — not a block.
            if c == 403 { await sessionBlocked() }
            throw RedditError.blocked(c)
        }
    }

    /// Three block pages in a row pause the session route: 1h, doubling up to 8h.
    private func sessionBlocked() async {
        sessionStreak += 1
        guard sessionStreak >= 3 else { return }
        sessionStreak = 0
        let hours = min(8.0, pow(2.0, Double(sessionCooldownLevel)))
        sessionCooldownLevel += 1
        let until = Date().addingTimeInterval(hours * 3600)
        await MainActor.run { AppSettings.shared.sessionCooldownUntil = until }
    }

    enum WhoAmI { case signedIn(String), signedOut, unknown }

    /// Save or unsave a post/comment on the user's Reddit account.
    func save(_ fullname: String, save: Bool) async throws {
        try await postForm(save ? "/api/save" : "/api/unsave", body: "id=\(fullname)")
    }

    /// Authenticated form POST on www using the web session and modhash.
    private func postForm(_ path: String, body: String) async throws {
        let cookie = await RedditAccount.cookieHeader()
        guard cookie.contains("reddit_session="), let modhash else { throw RedditError.loginRequired }
        if userAgent == nil { userAgent = await MainActor.run { WebTransport.safariUserAgent } }
        try await acquireSlot()
        var req = URLRequest(url: URL(string: "https://www.reddit.com" + path)!)
        req.httpMethod = "POST"
        req.httpShouldHandleCookies = false
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(modhash, forHTTPHeaderField: "X-Modhash")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: req, delegate: redirectCatcher)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        await log("write", req.url!, status, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "", nil, data)
        guard (200..<300).contains(status) else { throw RedditError.http(status) }
    }

    /// Join or leave a community on the user's Reddit account (POST /api/subscribe on www,
    /// authenticated by the web session and its modhash).
    func subscribe(_ name: String, join: Bool) async throws {
        let cookie = await RedditAccount.cookieHeader()
        guard cookie.contains("reddit_session="), let modhash else { throw RedditError.loginRequired }
        if userAgent == nil { userAgent = await MainActor.run { WebTransport.safariUserAgent } }
        try await acquireSlot()
        var req = URLRequest(url: URL(string: "https://www.reddit.com/api/subscribe")!)
        req.httpMethod = "POST"
        req.httpShouldHandleCookies = false
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(modhash, forHTTPHeaderField: "X-Modhash")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let sr = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        req.httpBody = Data("action=\(join ? "sub" : "unsub")&sr_name=\(sr)&api_type=json".utf8)
        let (data, response) = try await session.data(for: req, delegate: redirectCatcher)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        await log("write", req.url!, status, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "", nil, data)
        guard (200..<300).contains(status) else { throw RedditError.http(status) }
    }

    /// Verify the web session with www.reddit.com/api/me.json (the endpoint the website itself uses).
    /// Never counts toward the session-route cooldown.
    func whoAmI() async -> WhoAmI {
        let cookie = await RedditAccount.cookieHeader()
        guard cookie.contains("reddit_session=") else { return .signedOut }
        if userAgent == nil { userAgent = await MainActor.run { WebTransport.safariUserAgent } }
        guard let url = URL(string: "https://www.reddit.com/api/me.json?raw_json=1") else { return .unknown }
        do {
            try await acquireSlot()
            var req = URLRequest(url: url)
            req.httpShouldHandleCookies = false
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: req, delegate: redirectCatcher)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            let ct = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            await log("me", url, http.statusCode, ct, http.value(forHTTPHeaderField: "Location"), data)
            guard http.statusCode == 200, ct.contains("json") else {
                return (300..<400).contains(http.statusCode) ? .signedOut : .unknown
            }
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let d = (obj?["data"] as? [String: Any]) ?? obj
            if let mh = d?["modhash"] as? String, !mh.isEmpty { modhash = mh }
            if let name = d?["name"] as? String, !name.isEmpty { return .signedIn(name) }
            return .signedOut
        } catch {
            return .unknown
        }
    }

    /// Official API: https://oauth.reddit.com with the user's own OAuth token.
    private func viaAPI(_ path: String) async throws -> Data {
        let (clientID, ua) = await MainActor.run { (AppSettings.shared.apiClientID, AppSettings.shared.apiUserAgent) }
        var token = try await RedditAPIAuth.shared.accessToken(clientID: clientID, userAgent: ua)
        let sep = path.contains("?") ? "&" : "?"
        let p = Self.oauthPath(path)
        guard let url = URL(string: "https://oauth.reddit.com" + p + (p.contains("?") ? "&" : "?") + "raw_json=1") else { throw RedditError.notFound }
        _ = sep
        for attempt in 0..<2 {
            var req = URLRequest(url: url)
            req.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch let e as URLError where [URLError.Code.notConnectedToInternet, URLError.Code.networkConnectionLost, URLError.Code.dataNotAllowed].contains(e.code) {
                throw RedditError.offline
            }
            guard let http = response as? HTTPURLResponse else { throw RedditError.http(0) }
            let ct = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            await log("api", url, http.statusCode, ct, nil, data)
            if http.statusCode == 401 && attempt == 0 {
                token = try await RedditAPIAuth.shared.accessToken(clientID: clientID, userAgent: ua, forceRefresh: true)
                continue
            }
            return try await interpret(status: http.statusCode, contentType: ct, retryAfter: http.value(forHTTPHeaderField: "Retry-After"), data: data)
        }
        throw RedditError.apiNotSignedIn
    }

    private func viaBrowser(_ url: URL) async throws -> Data {
        let r = try await WebTransport.shared.fetch(url)
        let redirectedAway = r.finalURL.map { !Self.isJSONResource($0) } ?? false
        await log("browser", url, r.status, r.contentType, redirectedAway ? r.finalURL?.absoluteString : nil, r.data)
        if r.status == 429 { return try await interpret(status: 429, contentType: r.contentType, retryAfter: r.retryAfter, data: r.data) }
        if redirectedAway {
            if let f = r.finalURL, Self.isLoginWall(f) { throw RedditError.loginRequired }
            throw RedditError.blocked(r.status == 200 ? 302 : r.status)
        }
        return try await interpret(status: r.status, contentType: r.contentType, retryAfter: r.retryAfter, data: r.data)
    }

    private func interpret(status: Int, contentType: String, retryAfter: String?, data: Data) async throws -> Data {
        switch status {
        case 200..<300:
            if !contentType.contains("json") { throw RedditError.blocked(status) }
            return data
        case 429:
            let ra = Double(retryAfter ?? "") ?? 0
            backoffUntil = Date().addingTimeInterval(max(ra, 20))
            let until = backoffUntil
            await MainActor.run {
                NetworkStatus.shared.backoffUntil = until
                let s = AppSettings.shared
                if s.requestsPerMinute > 5 { s.requestsPerMinute -= 1 } // adapt downwards
            }
            throw RedditError.rateLimited
        case 403, 404:
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
            switch reason {
            case "private": throw RedditError.privateCommunity
            case "banned": throw RedditError.banned
            case "quarantined": throw RedditError.quarantined
            default:
                // A genuine missing subreddit/user comes back as Reddit JSON. An HTML 404 means the
                // request itself was filtered or rerouted, so let the fallbacks try.
                if status == 404 && contentType.contains("json") { throw RedditError.notFound }
                throw RedditError.blocked(status)
            }
        default:
            throw RedditError.http(status)
        }
    }

    func raw(_ path: String, kind: CacheKind, force: Bool) async throws -> (data: Data, fromCache: Bool, stale: Bool, age: TimeInterval, error: Error?) {
        let hit = cached(path)
        let age = hit.map { Date().timeIntervalSince($0.date) } ?? .infinity
        let ttl = await MainActor.run { kind.ttl }
        if let hit, !force, age < ttl {
            await MainActor.run { NetworkStatus.shared.cacheHits += 1 }
            return (hit.data, true, false, age, nil)
        }
        let task: Task<Data, Error>
        if let t = inflight[path] { task = t } else {
            let host = await MainActor.run { AppSettings.shared.source.host }
            task = Task { try await self.download(path, host: host) }
            inflight[path] = task
        }
        do {
            let data = try await task.value
            inflight[path] = nil
            store(path, data)
            await MainActor.run { NetworkStatus.shared.lastError = nil }
            return (data, false, false, 0, nil)
        } catch {
            inflight[path] = nil
            let msg = error.localizedDescription
            await MainActor.run { NetworkStatus.shared.lastError = msg }
            if let hit { return (hit.data, true, true, age, error) }
            throw error
        }
    }

    func get<T: Decodable>(_ path: String, as type: T.Type, kind: CacheKind = .list, force: Bool = false) async throws -> Fetched<T> {
        let r = try await raw(path, kind: kind, force: force)
        do {
            let v = try JSONDecoder().decode(T.self, from: r.data)
            return Fetched(value: v, fromCache: r.fromCache, stale: r.stale, age: r.age, error: r.error)
        } catch {
            throw RedditError.decoding
        }
    }
}

// MARK: - Endpoints

enum Reddit {
    static func q(_ items: [String: String?]) -> String {
        var c = URLComponents()
        c.queryItems = items.compactMap { k, v in
            guard let v, !v.isEmpty else { return nil }
            return URLQueryItem(name: k, value: v)
        }.sorted { $0.name < $1.name }
        guard let query = c.percentEncodedQuery, !query.isEmpty else { return "" }
        return "?" + query.replacingOccurrences(of: "+", with: "%2B")
    }

    /// Web mode: Reddit serves only a community's plain front page as JSON (`/r/pics/.json`);
    /// sorted pages are blocked, so only Hot is requested. API mode supports every sort.
    static var sortsAvailable: Bool { AppSettings.shared.fullAccess }
    /// Full feature set (own API key or working web session); endpoints use oauth-style paths.
    static var apiActive: Bool { AppSettings.shared.fullAccess }

    static func listing(_ path: String, sort: SortOrder, time: TimeRange, after: String?, force: Bool = false) async throws -> Fetched<ListingResponse> {
        let api = apiActive
        let base = path.isEmpty ? "" : "/\(path)"
        let page: String
        if api {
            page = "\(base)/\(sort.rawValue)"
        } else {
            page = base.isEmpty ? "/" : base
        }
        let t: String? = api && sort.needsTime ? time.rawValue : nil
        return try await RedditClient.shared.get(page + ".json" + q(["limit": api ? "25" : nil, "t": t, "after": after, "sr_detail": api ? "1" : nil]), as: ListingResponse.self, force: force)
    }

    /// A post's own page + `.json` (e.g. `/r/pics/comments/abc/title/.json`), as Safari would load it.
    static func comments(postID: String, permalink: String?, commentID: String?, sort: CommentSort, force: Bool = false) async throws -> Fetched<[ListingResponse]> {
        if apiActive {
            let path = "/comments/\(postID)" + (commentID.map { "/_/\($0)" } ?? "") + ".json"
            return try await RedditClient.shared.get(path + q(["sort": sort.rawValue, "limit": "200", "context": commentID == nil ? nil : "3"]), as: [ListingResponse].self, kind: .post, force: force)
        }
        var base: String
        if var p = permalink, p.hasPrefix("/") {
            if !p.hasSuffix("/") { p += "/" }
            base = p
        } else {
            base = "/comments/\(postID)/"
        }
        if let commentID { base += (permalink == nil ? "_/" : "") + "\(commentID)/" }
        let path = base + ".json" + q(["sort": sort == .confidence ? nil : sort.rawValue, "context": commentID == nil ? nil : "3"])
        return try await RedditClient.shared.get(path, as: [ListingResponse].self, kind: .post, force: force)
    }

    static func moreChildren(postID: String, ids: [String], sort: CommentSort) async throws -> [Thing] {
        let r = try await RedditClient.shared.get("/api/morechildren.json" + q(["api_type": "json", "link_id": "t3_\(postID)", "children": ids.joined(separator: ","), "sort": sort.rawValue, "limit_children": "false"]), as: MoreChildrenResponse.self, kind: .post)
        return r.value.json.data?.things ?? []
    }

    static func about(_ sub: String) async throws -> Subreddit {
        try await RedditClient.shared.get("/r/\(sub)/about.json", as: Wrapped<Subreddit>.self, kind: .about).value.data
    }

    static func searchPosts(_ query: String, sub: String?, sort: String, time: TimeRange, after: String?) async throws -> Fetched<ListingResponse> {
        let nsfw = AppSettings.shared.nsfw != .hide
        let path = sub.map { "/r/\($0)/search.json" } ?? "/search.json"
        return try await RedditClient.shared.get(path + q(["q": query, "sort": sort, "t": time.rawValue, "after": after, "restrict_sr": sub == nil ? nil : "1", "include_over_18": nsfw ? "on" : nil, "limit": "25", "type": "link"]), as: ListingResponse.self)
    }

    static func searchSubreddits(_ query: String, after: String?) async throws -> Fetched<ListingResponse> {
        let nsfw = AppSettings.shared.nsfw != .hide
        return try await RedditClient.shared.get("/subreddits/search.json" + q(["q": query, "after": after, "limit": "25", "include_over_18": nsfw ? "on" : nil]), as: ListingResponse.self)
    }

    static func searchUsers(_ query: String, after: String?) async throws -> Fetched<ListingResponse> {
        try await RedditClient.shared.get("/users/search.json" + q(["q": query, "after": after, "limit": "25"]), as: ListingResponse.self)
    }

    static func popularSubreddits(after: String?) async throws -> Fetched<ListingResponse> {
        try await RedditClient.shared.get("/subreddits/popular.json" + q(["limit": "50", "after": after]), as: ListingResponse.self, kind: .about)
    }

    /// The signed-in account's subscribed communities (`/subreddits/mine/subscriber/.json`).
    static func mySubscriptions() async throws -> [(name: String, icon: URL?)] {
        var out: [(name: String, icon: URL?)] = []
        var after: String? = nil
        for _ in 0..<5 {
            let r = try await RedditClient.shared.get("/subreddits/mine/subscriber.json" + q(["limit": "100", "after": after]), as: ListingResponse.self, kind: .about)
            for t in r.value.data.children { if case .subreddit(let s) = t { out.append((s.display_name, s.iconURL)) } }
            after = r.value.data.after
            if after == nil { break }
        }
        return out
    }

    /// Profile info for up to 100 accounts in one request.
    static func userData(ids: [String]) async throws -> [String: UserDataInfo] {
        try await RedditClient.shared.get("/api/user_data_by_account_ids.json" + q(["ids": ids.joined(separator: ",")]), as: [String: UserDataInfo].self, kind: .about).value
    }

    static func userSaved(_ name: String, after: String?, force: Bool = false) async throws -> Fetched<ListingResponse> {
        try await RedditClient.shared.get("/user/\(name)/saved.json" + q(["after": after, "limit": "25", "sr_detail": apiActive ? "1" : nil]), as: ListingResponse.self, force: force)
    }

    static func user(_ name: String) async throws -> RedditUser {
        try await RedditClient.shared.get("/user/\(name)/about.json", as: Wrapped<RedditUser>.self, kind: .about).value.data
    }

    static func userListing(_ name: String, after: String?, force: Bool = false) async throws -> Fetched<ListingResponse> {
        let path = apiActive ? "/user/\(name)/overview.json" : "/user/\(name).json"
        return try await RedditClient.shared.get(path + q(["after": after]), as: ListingResponse.self, force: force)
    }
}
