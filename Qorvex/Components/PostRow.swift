import SwiftUI

extension Int {
    var compact: String {
        let n = Double(self), a = abs(n)
        if a >= 1_000_000 { return String(format: a >= 10_000_000 ? "%.0fm" : "%.1fm", n / 1_000_000).replacingOccurrences(of: ".0m", with: "m") }
        if a >= 1_000 { return String(format: a >= 10_000 ? "%.0fk" : "%.1fk", n / 1_000).replacingOccurrences(of: ".0k", with: "k") }
        return String(self)
    }
}

extension Date {
    var ago: String {
        let s = max(0, Date().timeIntervalSince(self))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 86400 * 30 { return "\(Int(s / 86400))d" }
        if s < 86400 * 365 { return "\(Int(s / (86400 * 30)))mo" }
        return "\(Int(s / (86400 * 365)))y"
    }
}

extension Color {
    init?(hex: String?) {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

struct FlairView: View {
    let text: String
    var bg: String? = nil
    var light = false
    var body: some View {
        let c = Color(hex: bg)
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(c == nil ? Color.secondary : (light ? Color.white : Color.black.opacity(0.85)))
            .background(c ?? Color.secondary.opacity(0.15), in: Capsule())
    }
}

struct Badge: View {
    let text: String
    var icon: String? = nil
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }
}

struct PostBadges: View {
    let post: Post
    var body: some View {
        let s = AppSettings.shared
        let any = post.stickied == true || post.over_18 == true || post.spoiler == true || post.locked == true || post.crosspost_parent_list?.isEmpty == false || (s.showFlair && post.link_flair_text?.isEmpty == false)
        if any {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if post.stickied == true { Badge(text: "Pinned", icon: "pin.fill", color: .green) }
                    if post.over_18 == true { Badge(text: "NSFW", color: .red) }
                    if post.spoiler == true { Badge(text: "Spoiler", color: .orange) }
                    if post.locked == true { Badge(text: "Locked", icon: "lock.fill", color: .yellow) }
                    if let x = post.crosspost_parent_list?.first { Badge(text: "r/\(x.subreddit)", icon: "arrow.triangle.branch", color: .blue) }
                    if s.showFlair, let f = post.link_flair_text, !f.isEmpty {
                        FlairView(text: f, bg: post.link_flair_background_color, light: post.link_flair_text_color == "light")
                    }
                }
            }
            .scrollDisabled(true)
        }
    }
}

/// A post in a feed. Card or compact layout, driven by settings.
struct PostRow: View {
    let post: Post
    var showSubreddit = true
    @Environment(Router.self) private var router
    private var settings: AppSettings { .shared }
    private var library: Library { .shared }

    var body: some View {
        let read = settings.dimRead && library.isRead(post.id)
        Group {
            if settings.layout == .compact { compact } else { card }
        }
        .opacity(read ? 0.62 : 1)
        .contentShape(Rectangle())
        .onTapGesture { Haptics.tap(.soft); router.open(post) }
    }

    private var meta: some View {
        HStack(spacing: 6) {
            if showSubreddit {
                Button { router.push(.feed(.subreddit(post.subreddit))) } label: {
                    HStack(spacing: 6) {
                        Avatar(name: post.subreddit, size: 20)
                        Text("r/\(post.subreddit)").fontWeight(.semibold).foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
            }
            Button { router.push(.user(post.author)) } label: {
                Text(showSubreddit ? post.author : "u/\(post.author)").lineLimit(1)
            }
            .buttonStyle(.plain)
            Text("·")
            Text(post.created.ago)
            if settings.layout == .card, post.isExternalLink, let d = post.domain {
                Text("·")
                Text(d).lineLimit(1)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var stats: some View {
        HStack(spacing: 16) {
            Label((post.score ?? 0).compact, systemImage: "arrow.up")
            Label((post.num_comments ?? 0).compact, systemImage: "bubble.left")
            Spacer()
            if library.isSaved(post.id) {
                Image(systemName: "bookmark.fill").foregroundStyle(Color.accentColor)
            }
            PostMenu(post: post) {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 24)
                    .contentShape(Rectangle())
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .labelStyle(TightLabel())
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 9) {
            meta
            Text(post.title)
                .font(.system(.headline, design: .default).weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            PostBadges(post: post)
            if case .text = post.mediaKind, let t = post.selftext, !t.isEmpty {
                Text(Markdown.plain(String(t.prefix(400))))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .blur(radius: post.spoiler == true && settings.blurSpoilers ? 6 : 0)
            }
            PostMediaView(post: post)
            stats
        }
        .padding(14)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var compact: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                meta
                Text(post.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                PostBadges(post: post)
                stats
            }
            if settings.showThumbnails { CompactThumb(post: post) }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }
}

private struct CompactThumb: View {
    let post: Post
    var body: some View {
        let media = post.mediaKind
        let blur = (post.over_18 == true && AppSettings.shared.nsfw == .blur) || (post.spoiler == true && AppSettings.shared.blurSpoilers)
        let info: (URL?, String?)? = {
            switch media {
            case .image(let e): return (post.previewImage(target: 240)?.url ?? e.url, nil)
            case .gallery(let es): return (es.first?.url, "square.stack.fill")
            case .video(let v): return (v.poster, "play.fill")
            case .youtube(_, _, let t): return (t, "play.fill")
            case .link(_, _, let t): return (t, "link")
            default: return nil
            }
        }()
        if let info {
            ZStack(alignment: .bottomTrailing) {
                if let u = info.0 { RemoteImage(url: u) } else {
                    Image(systemName: "safari").font(.title3).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.secondary.opacity(0.12))
                }
                if let icon = info.1 {
                    Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(5).background(.black.opacity(0.55), in: Circle()).padding(4)
                }
            }
            .frame(width: 76, height: 76)
            .blur(radius: blur ? 10 : 0)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                switch media {
                case .image(let e): Presenter.shared.viewer = ViewerItem(entries: [e], index: 0, title: post.title)
                case .gallery(let es): Presenter.shared.viewer = ViewerItem(entries: es, index: 0, title: post.title)
                case .video(let v): if let u = v.playURL { Presenter.shared.video = VideoItem(url: u) }
                case .youtube(_, let u, _): UIApplication.shared.open(u)
                case .link(let u, _, _): Presenter.shared.openExternal(u)
                default: break
                }
            }
        }
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

/// The "…" menu and long-press menu shared by feeds and post detail.
struct PostMenu<LabelView: View>: View {
    let post: Post
    @ViewBuilder var label: () -> LabelView
    @Environment(Router.self) private var router

    var body: some View {
        Menu { PostMenuItems(post: post, router: router) } label: { label() }
            .buttonStyle(.plain)
    }
}

struct PostMenuItems: View {
    let post: Post
    let router: Router
    private var library: Library { .shared }

    var body: some View {
        Section {
            Button {
                let on = library.toggleSave(post)
                Haptics.success()
                Presenter.shared.show(on ? "Saved" : "Removed from Saved")
            } label: { Label(library.isSaved(post.id) ? "Unsave" : "Save", systemImage: library.isSaved(post.id) ? "bookmark.slash" : "bookmark") }
            Button { library.hide(post.id); Presenter.shared.show("Post hidden") } label: { Label("Hide", systemImage: "eye.slash") }
            ShareLink(item: post.webURL, subject: Text(post.title)) { Label("Share", systemImage: "square.and.arrow.up") }
            Button { UIPasteboard.general.url = post.webURL; Presenter.shared.show("Link copied") } label: { Label("Copy Link", systemImage: "link") }
        }
        Section {
            if post.isExternalLink, let u = post.linkURL {
                Button { Presenter.shared.openExternal(u) } label: { Label("Open Link", systemImage: "safari") }
            }
            Button { UIApplication.shared.open(post.webURL) } label: { Label("Open on reddit.com", systemImage: "globe") }
        }
        Section("Go to") {
            Button { router.push(.feed(.subreddit(post.subreddit))) } label: { Label("r/\(post.subreddit)", systemImage: "person.3") }
            Button { router.push(.user(post.author)) } label: { Label("u/\(post.author)", systemImage: "person.crop.circle") }
        }
        Section("Filter") {
            Button(role: .destructive) { library.filters.subreddits.append(post.subreddit); Presenter.shared.show("r/\(post.subreddit) filtered") } label: {
                Label("Hide posts from r/\(post.subreddit)", systemImage: "nosign")
            }
            Button(role: .destructive) { library.filters.users.append(post.author); Presenter.shared.show("u/\(post.author) filtered") } label: {
                Label("Hide posts by u/\(post.author)", systemImage: "person.crop.circle.badge.xmark")
            }
            if post.isExternalLink, let d = post.domain {
                Button(role: .destructive) { library.filters.domains.append(d); Presenter.shared.show("\(d) filtered") } label: {
                    Label("Hide links to \(d)", systemImage: "link.badge.plus")
                }
            }
        }
    }
}

extension Color {
    static var cardBackground: Color { Color(uiColor: UIColor { t in
        if t.userInterfaceStyle == .dark { return AppSettings.shared.theme == .black ? UIColor(white: 0.07, alpha: 1) : UIColor(white: 0.11, alpha: 1) }
        return .white
    }) }
    static var appBackground: Color { Color(uiColor: UIColor { t in
        if t.userInterfaceStyle == .dark { return AppSettings.shared.theme == .black ? .black : UIColor(white: 0.04, alpha: 1) }
        return UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1)
    }) }
}
