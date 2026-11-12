import SwiftUI
import Observation

enum FeedSource: Hashable {
    case home, popular, all
    case subreddit(String)
    case custom(UUID)

    var title: String {
        switch self {
        case .home: return "Home"
        case .popular: return "Popular"
        case .all: return "All"
        case .subreddit(let s): return "r/\(s)"
        case .custom(let id): return Library.shared.feeds.first { $0.id == id }?.name ?? "Feed"
        }
    }

    var path: String {
        switch self {
        case .home:
            let s = Library.shared.subs
            return s.isEmpty ? "r/popular" : "r/" + s.joined(separator: "+")
        case .popular: return "r/popular"
        case .all: return "r/all"
        case .subreddit(let s): return "r/\(s)"
        case .custom(let id):
            let subs = Library.shared.feeds.first { $0.id == id }?.subs ?? []
            return subs.isEmpty ? "r/popular" : "r/" + subs.joined(separator: "+")
        }
    }

    var subredditName: String? { if case .subreddit(let s) = self { return s } else { return nil } }
}

struct PostRef: Hashable {
    let id: String
    var commentID: String?
    var preview: Post?

    static func == (a: PostRef, b: PostRef) -> Bool { a.id == b.id && a.commentID == b.commentID }
    func hash(into h: inout Hasher) { h.combine(id); h.combine(commentID) }
}

enum Route: Hashable {
    case feed(FeedSource)
    case post(PostRef)
    case user(String)
    case search(sub: String?)
    case saved, history, discover

    /// Maps a reddit.com / redd.it link to an in-app screen.
    static func from(url: URL) -> Route? {
        if url.scheme == "qorvex" {
            let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
            if parts.count >= 2, parts[0] == "r" { return .feed(.subreddit(parts[1])) }
            if parts.count >= 2, parts[0] == "u" { return .user(parts[1]) }
            return nil
        }
        guard let host = url.host?.lowercased() else {
            // relative link like /r/foo
            guard url.absoluteString.hasPrefix("/"), let abs = URL(string: "https://www.reddit.com" + url.absoluteString) else { return nil }
            return from(url: abs)
        }
        let p = url.pathComponents.filter { $0 != "/" }
        if host.hasSuffix("redd.it"), host != "i.redd.it", host != "v.redd.it", host != "preview.redd.it", let id = p.first {
            return .post(PostRef(id: id))
        }
        guard host == "reddit.com" || host.hasSuffix(".reddit.com") else { return nil }
        if p.count >= 2, p[0] == "r" {
            if p.count >= 4, p[2] == "comments" { return .post(PostRef(id: p[3], commentID: p.count >= 6 ? p[5] : nil)) }
            if p.count >= 3, p[2] == "s" { return nil }
            if p.count >= 3, p[2] == "wiki" { return nil }
            return .feed(.subreddit(p[1]))
        }
        if p.count >= 2, p[0] == "comments" { return .post(PostRef(id: p[1], commentID: p.count >= 4 ? p[3] : nil)) }
        if p.count >= 2, p[0] == "u" || p[0] == "user" { return .user(p[1]) }
        return nil
    }
}

/// Per-navigation-stack router. With two-pane on, the list router forwards post opens to the
/// detail column of a NavigationSplitView. The split view collapses to a single stack on narrow
/// screens (e.g. iPhone Duo's outer display) and expands when unfolded, keeping the open post.
@Observable
final class Router {
    var path = NavigationPath()
    var detailRoot: PostRef?
    var compactColumn: NavigationSplitViewColumn = .sidebar
    var columns: NavigationSplitViewVisibility = .all
    @ObservationIgnored weak var detail: Router?
    /// Set on the detail router: communities, users and other browse screens open in the list pane.
    @ObservationIgnored weak var list: Router?
    @ObservationIgnored var splitActive = false

    func push(_ r: Route) {
        if let list {
            switch r {
            case .post:
                path.append(r)
            default:
                list.path.append(r)
                list.compactColumn = .sidebar
                list.columns = .all
            }
            return
        }
        path.append(r)
    }

    func open(_ post: Post) {
        Library.shared.markRead(post)
        open(PostRef(id: post.id, preview: post))
    }

    func open(_ ref: PostRef) {
        if splitActive, let d = detail {
            d.path = NavigationPath()
            d.detailRoot = ref
            compactColumn = .detail
            columns = .all
        } else {
            path.append(Route.post(ref))
        }
    }
}

struct ViewerItem: Identifiable {
    let id = UUID()
    let entries: [GalleryEntry]
    let index: Int
    let title: String
}

struct VideoItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// App-wide presentation: in-app browser, media viewer, toasts.
@MainActor @Observable
final class Presenter {
    static let shared = Presenter()
    var safari: IdentifiableURL?
    var viewer: ViewerItem?
    var video: VideoItem?
    var toast: String?
    var verify = false
    @ObservationIgnored var afterVerify: (() -> Void)?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    func show(_ message: String) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.3)) { toast = message }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.toast = nil }
        }
    }

    func openExternal(_ url: URL) {
        guard url.scheme == "http" || url.scheme == "https" else { UIApplication.shared.open(url); return }
        if Post.youtubeID(url.absoluteString) != nil { UIApplication.shared.open(url); return }
        if AppSettings.shared.inAppBrowser { safari = IdentifiableURL(url: url) } else { UIApplication.shared.open(url) }
    }
}

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

extension View {
    /// Routes taps on links in text: reddit links stay in-app, everything else opens in the browser.
    @MainActor func handlesLinks(_ router: Router) -> some View {
        environment(\.openURL, OpenURLAction { url in
            if url.scheme == "spoiler" { return .discarded }
            if let r = Route.from(url: url) {
                if case .post(let ref) = r { router.open(ref) } else { router.push(r) }
            } else {
                Presenter.shared.openExternal(url)
            }
            return .handled
        })
    }
}
