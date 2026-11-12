import Foundation
import WebKit
import SwiftUI

/// Fetches Reddit JSON through a real WebKit browser engine, using the user's signed-in reddit.com
/// session from the shared website data store.
///
/// Two methods: a same-origin `fetch()` from inside a reddit.com page (fast), and — if Reddit still
/// treats that as signed out — a top-level navigation to the JSON URL, exactly like typing it into
/// Safari, then reading the page text.
@MainActor
final class WebTransport: NSObject, WKNavigationDelegate {
    static let shared = WebTransport()

    private var webView: WKWebView
    private var loadedOrigin: String?
    private var fullyPrimed: Set<String> = []
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var loading = false
    private var lastResponse: HTTPURLResponse?
    private var preferNavigation = false
    private var triedNavigation = false
    private var lastFullPrime = Date.distantPast

    override init() {
        webView = WebTransport.makeWebView()
        super.init()
        webView.navigationDelegate = self
    }

    private static func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        let v = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: cfg)
        v.isUserInteractionEnabled = false
        v.alpha = 0.01
        v.customUserAgent = nil
        return v
    }

    /// The real Safari user agent of this device, used for direct requests too.
    static var safariUserAgent: String {
        let v = UIDevice.current.systemVersion
        let major = v.split(separator: ".").first.map(String.init) ?? "18"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(v.replacingOccurrences(of: ".", with: "_")) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
    }

    /// Throw away the hidden browser and start a fresh one, so it picks up a new sign-in.
    func reset() {
        finish(CancellationError())
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        webView = WebTransport.makeWebView()
        webView.navigationDelegate = self
        loadedOrigin = nil
        fullyPrimed = []
        preferNavigation = false
        triedNavigation = false
    }

    struct Response {
        let status: Int
        let contentType: String
        let data: Data
        let retryAfter: String?
        let finalURL: URL?
    }

    func fetch(_ url: URL) async throws -> Response {
        guard let scheme = url.scheme, let host = url.host else { throw RedditError.notFound }
        let origin = "\(scheme)://\(host)"
        await syncCookiesToURLSession()

        if preferNavigation { return try await navigate(url) }

        try await prime(origin, full: false)
        var r = try await run(url)
        if r.status == 429 { return r }
        if Self.looksBlocked(r), Date().timeIntervalSince(lastFullPrime) > 600 {
            // Open the real front page (at most every 10 min) so the session is established, then retry once.
            lastFullPrime = Date()
            try await prime(origin, full: true)
            r = try await run(url)
            if r.status == 429 { return r }
        }
        if Self.looksBlocked(r) && !triedNavigation {
            triedNavigation = true
            await logCookies(for: url)
            // fetch() was treated as signed out; try loading the JSON as a normal page, once per launch.
            let n = try await navigate(url)
            if !Self.looksBlocked(n) { preferNavigation = true }
            return n
        }
        return r
    }

    static func looksBlocked(_ r: Response) -> Bool {
        r.status == 403 || r.status == 404 || !r.contentType.contains("json")
            || (r.finalURL.map { !$0.path.hasSuffix(".json") } ?? false)
    }

    private func run(_ url: URL) async throws -> Response {
        let js = """
        const r = await fetch(u, { credentials: 'include', headers: { 'Accept': 'application/json' } });
        const t = await r.text();
        return [r.status, r.headers.get('content-type') || '', t, r.headers.get('retry-after') || '', r.url || ''];
        """
        let result = try await webView.callAsyncJavaScript(js, arguments: ["u": url.absoluteString], in: nil, contentWorld: .defaultClient)
        guard let arr = result as? [Any], arr.count == 5 else { throw RedditError.http(0) }
        let status = (arr[0] as? NSNumber)?.intValue ?? 0
        let ct = arr[1] as? String ?? ""
        let body = arr[2] as? String ?? ""
        let ra = arr[3] as? String
        let final = (arr[4] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return Response(status: status, contentType: ct, data: Data(body.utf8), retryAfter: ra?.isEmpty == false ? ra : nil, finalURL: final)
    }

    /// Load the JSON URL as a top-level page (like Safari's address bar) and read its text.
    private func navigate(_ url: URL) async throws -> Response {
        try await load(url)
        let finalURL = webView.url
        if let s = url.scheme, let h = finalURL?.host { loadedOrigin = "\(s)://\(h)" }
        let text = try await webView.callAsyncJavaScript("return document.body ? document.body.innerText : ''", arguments: [:], in: nil, contentWorld: .defaultClient) as? String ?? ""
        let resp = lastResponse
        var ct = resp?.value(forHTTPHeaderField: "Content-Type") ?? resp?.mimeType ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ct.contains("json"), trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { ct = "application/json" }
        return Response(status: resp?.statusCode ?? 0, contentType: ct, data: Data(trimmed.utf8),
                        retryAfter: resp?.value(forHTTPHeaderField: "Retry-After"), finalURL: finalURL)
    }

    private func prime(_ origin: String, full: Bool) async throws {
        if loadedOrigin == origin && !full { return }
        try await load(URL(string: full ? origin + "/" : origin + "/robots.txt")!)
        loadedOrigin = origin
    }

    private func load(_ url: URL) async throws {
        attachIfNeeded()
        lastResponse = nil
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            waiters.append(c)
            if !loading {
                loading = true
                webView.load(URLRequest(url: url, timeoutInterval: 20))
            }
        }
    }

    /// WebKit throttles views that aren't in a window, so keep it (invisibly) in the key window.
    private func attachIfNeeded() {
        guard webView.superview == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        window?.insertSubview(webView, at: 0)
    }

    private func finish(_ error: Error?) {
        loading = false
        let w = waiters
        waiters = []
        for c in w {
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }

    private func syncCookiesToURLSession() async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for c in cookies where c.domain.contains("reddit.com") { HTTPCookieStorage.shared.setCookie(c) }
    }

    /// Diagnostic: which Reddit cookies (names and domains only, never values) apply to this URL.
    private func logCookies(for url: URL) async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let host = url.host ?? ""
        let applicable = cookies.filter { c in
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return host == d || host.hasSuffix("." + d)
        }
        let names = applicable.map { "\($0.name)@\($0.domain)" }.sorted().joined(separator: ", ")
        NetworkStatus.shared.record(RequestLog(via: "cookies", url: url.host ?? "", status: applicable.count,
                                               contentType: "cookies sent to this host",
                                               location: nil, snippet: names.isEmpty ? "(none)" : names))
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame { lastResponse = navigationResponse.response as? HTTPURLResponse }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorNotConnectedToInternet { finish(RedditError.offline) } else { finish(error) }
    }
}

/// The user's own reddit.com web session (cookies in the shared WebKit store). Reddit requires a
/// signed-in session to read feed data; signing in happens on Reddit's own page, so Qorvex never
/// sees the password.
@MainActor
enum RedditAccount {
    static func isSignedIn() async -> Bool {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookies.contains { $0.name == "reddit_session" && $0.domain.contains("reddit.com") && ($0.expiresDate ?? .distantFuture) > Date() }
    }

    static func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records.filter { $0.displayName.contains("reddit") })
        for c in HTTPCookieStorage.shared.cookies ?? [] where c.domain.contains("reddit.com") { HTTPCookieStorage.shared.deleteCookie(c) }
        WebTransport.shared.reset()
        NetworkStatus.shared.signedIn = false
    }

    static func refresh() async {
        NetworkStatus.shared.signedIn = await isSignedIn()
    }
}

/// Reddit's own login page in a sheet. Closes itself as soon as the session cookie appears.
struct RedditVerifyView: View {
    @Environment(\.dismiss) private var dismiss
    var onDone: () -> Void = {}
    @State private var finished = false

    var body: some View {
        NavigationStack {
            VerifyWebView(url: URL(string: "https://www.reddit.com/login/")!)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign in to Reddit")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top) {
                    Label("You're signing in on reddit.com. Qorvex never sees your password.", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { Task { await complete() } }.fontWeight(.semibold)
                    }
                }
                .task {
                    // Watch for the session cookie and finish automatically once signed in.
                    while !Task.isCancelled && !finished {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if await RedditAccount.isSignedIn() { await complete(); break }
                    }
                }
        }
    }

    private func complete() async {
        guard !finished else { return }
        finished = true
        WebTransport.shared.reset()
        await RedditAccount.refresh()
        NetworkStatus.shared.blocked = false
        NetworkStatus.shared.loginRequired = false
        await RedditClient.shared.clearLoginWall()
        if NetworkStatus.shared.signedIn {
            Haptics.success()
            Presenter.shared.show("Signed in to Reddit")
        }
        onDone()
        dismiss()
    }
}

private struct VerifyWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.allowsBackForwardNavigationGestures = true
        v.load(URLRequest(url: url))
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
