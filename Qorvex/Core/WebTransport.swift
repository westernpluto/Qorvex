import Foundation
import WebKit
import SwiftUI

/// Fetches Reddit JSON through a real WebKit browser engine. A hidden WKWebView opens a page on
/// reddit.com, then runs `fetch()` from inside it, so requests carry the same cookies, headers and
/// TLS fingerprint as Safari. Cookies live in the shared website data store, so passing Reddit's
/// check once (see `RedditVerifyView`) also unlocks these requests.
@MainActor
final class WebTransport: NSObject, WKNavigationDelegate {
    static let shared = WebTransport()

    private let webView: WKWebView
    private var loadedOrigin: String?
    private var fullyPrimed: Set<String> = []
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var loading = false

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
    }

    /// The real Safari user agent of this device, used for direct requests too.
    static var safariUserAgent: String {
        let v = UIDevice.current.systemVersion
        let major = v.split(separator: ".").first.map(String.init) ?? "18"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(v.replacingOccurrences(of: ".", with: "_")) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
    }

    /// Forget the loaded page so the next request re-opens Reddit (e.g. after verification).
    func reset() {
        loadedOrigin = nil
        fullyPrimed = []
    }

    struct Response {
        let status: Int
        let contentType: String
        let data: Data
        let retryAfter: String?
    }

    func fetch(_ url: URL) async throws -> Response {
        guard let scheme = url.scheme, let host = url.host else { throw RedditError.notFound }
        let origin = "\(scheme)://\(host)"
        try await prime(origin, full: fullyPrimed.contains(origin))
        var r = try await run(url)
        if Self.looksBlocked(r), !fullyPrimed.contains(origin) {
            // A lightweight page wasn't enough; open the real front page once so any check runs.
            fullyPrimed.insert(origin)
            try await prime(origin, full: true)
            r = try await run(url)
        }
        await syncCookiesToURLSession()
        return r
    }

    static func looksBlocked(_ r: Response) -> Bool {
        r.status == 403 || (r.status == 200 && !r.contentType.contains("json"))
    }

    private func run(_ url: URL) async throws -> Response {
        let js = """
        const r = await fetch(u, { credentials: 'include', headers: { 'Accept': 'application/json' } });
        const t = await r.text();
        return [r.status, r.headers.get('content-type') || '', t, r.headers.get('retry-after') || ''];
        """
        let result = try await webView.callAsyncJavaScript(js, arguments: ["u": url.absoluteString], in: nil, contentWorld: .defaultClient)
        guard let arr = result as? [Any], arr.count == 4 else { throw RedditError.http(0) }
        let status = (arr[0] as? NSNumber)?.intValue ?? 0
        let ct = arr[1] as? String ?? ""
        let body = arr[2] as? String ?? ""
        let ra = arr[3] as? String
        return Response(status: status, contentType: ct, data: Data(body.utf8), retryAfter: ra?.isEmpty == false ? ra : nil)
    }

    private func prime(_ origin: String, full: Bool) async throws {
        if loadedOrigin == origin && !full { return }
        attachIfNeeded()
        let page = full ? origin + "/" : origin + "/robots.txt"
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            waiters.append(c)
            if !loading {
                loading = true
                webView.load(URLRequest(url: URL(string: page)!, timeoutInterval: 20))
            }
        }
        loadedOrigin = origin
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

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorNotConnectedToInternet { finish(RedditError.offline) } else { finish(error) }
    }
}

/// A visible reddit.com page so the user can pass any check Reddit shows. Shares cookies with
/// the hidden transport and with direct requests.
struct RedditVerifyView: View {
    @Environment(\.dismiss) private var dismiss
    var onDone: () -> Void = {}

    var body: some View {
        NavigationStack {
            VerifyWebView(url: URL(string: "https://www.reddit.com/")!)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Open Reddit")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top) {
                    Text("If Reddit shows a check, complete it here. Then tap Done.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            WebTransport.shared.reset()
                            Task { @MainActor in NetworkStatus.shared.blocked = false }
                            onDone()
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
        }
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
