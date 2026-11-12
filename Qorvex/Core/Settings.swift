import SwiftUI
import Observation

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark, black
    var id: String { rawValue }
    var label: String { ["system": "Automatic", "light": "Light", "dark": "Dark", "black": "Midnight Black"][rawValue]! }
    var scheme: ColorScheme? { self == .light ? .light : (self == .system ? nil : .dark) }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case orange, blue, purple, green, pink, teal, red, yellow
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .orange: return Color(red: 1.0, green: 0.36, blue: 0.13)
        case .blue: return Color(red: 0.04, green: 0.52, blue: 1.0)
        case .purple: return Color(red: 0.55, green: 0.36, blue: 0.96)
        case .green: return Color(red: 0.19, green: 0.78, blue: 0.35)
        case .pink: return Color(red: 1.0, green: 0.22, blue: 0.53)
        case .teal: return Color(red: 0.19, green: 0.69, blue: 0.78)
        case .red: return Color(red: 1.0, green: 0.23, blue: 0.19)
        case .yellow: return Color(red: 1.0, green: 0.72, blue: 0.0)
        }
    }
}

enum PostLayout: String, CaseIterable, Identifiable {
    case card, compact
    var id: String { rawValue }
    var label: String { self == .card ? "Cards" : "Compact" }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case hot, new, top, rising, controversial
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .hot: return "flame"
        case .new: return "clock"
        case .top: return "chart.bar"
        case .rising: return "chart.line.uptrend.xyaxis"
        case .controversial: return "bolt"
        }
    }
    var needsTime: Bool { self == .top || self == .controversial }
}

enum TimeRange: String, CaseIterable, Identifiable {
    case hour, day, week, month, year, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hour: return "Past Hour"
        case .day: return "Today"
        case .week: return "This Week"
        case .month: return "This Month"
        case .year: return "This Year"
        case .all: return "All Time"
        }
    }
}

enum CommentSort: String, CaseIterable, Identifiable {
    case confidence, top, new, controversial, old, qa
    var id: String { rawValue }
    var label: String {
        switch self {
        case .confidence: return "Best"
        case .qa: return "Q&A"
        default: return rawValue.capitalized
        }
    }
}

enum NSFWMode: String, CaseIterable, Identifiable {
    case hide, blur, show
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum CacheMode: String, CaseIterable, Identifiable {
    case fresh, balanced, saver
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fresh: return "Fresh (1 min)"
        case .balanced: return "Balanced (5 min)"
        case .saver: return "Saver (30 min)"
        }
    }
    var listTTL: TimeInterval { self == .fresh ? 60 : self == .balanced ? 300 : 1800 }
    var postTTL: TimeInterval { self == .fresh ? 45 : self == .balanced ? 180 : 1200 }
}

enum TextSize: String, CaseIterable, Identifiable {
    case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge
    var id: String { rawValue }
    var dynamic: DynamicTypeSize {
        switch self {
        case .xSmall: return .xSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .xLarge
        case .xxLarge: return .xxLarge
        case .xxxLarge: return .xxxLarge
        }
    }
    var label: String {
        switch self {
        case .xSmall: return "Extra Small"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Default"
        case .xLarge: return "Large"
        case .xxLarge: return "Extra Large"
        case .xxxLarge: return "Huge"
        }
    }
}

enum AutoplayMode: String, CaseIterable, Identifiable {
    case always, never
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ConnectionMode: String, CaseIterable, Identifiable {
    case automatic, direct, browser, api
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic (Web)"
        case .direct: return "Direct"
        case .browser: return "Browser Engine"
        case .api: return "Reddit API (Your Key)"
        }
    }
}

enum ImageSource: String, CaseIterable, Identifiable {
    case www, old
    var id: String { rawValue }
    var label: String { self == .www ? "www.reddit.com" : "old.reddit.com" }
    var host: String { self == .www ? "https://www.reddit.com" : "https://old.reddit.com" }
}

/// All user preferences, persisted to UserDefaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()
    @ObservationIgnored private let d = UserDefaults.standard

    var theme: AppTheme { didSet { d.set(theme.rawValue, forKey: "theme") } }
    var accent: AccentChoice { didSet { d.set(accent.rawValue, forKey: "accent") } }
    var textSize: TextSize { didSet { d.set(textSize.rawValue, forKey: "textSize") } }
    var layout: PostLayout { didSet { d.set(layout.rawValue, forKey: "layout") } }
    var twoPane: Bool { didSet { d.set(twoPane, forKey: "twoPane") } }
    var homeSort: SortOrder { didSet { d.set(homeSort.rawValue, forKey: "homeSort") } }
    var commentSort: CommentSort { didSet { d.set(commentSort.rawValue, forKey: "commentSort") } }
    var nsfw: NSFWMode { didSet { d.set(nsfw.rawValue, forKey: "nsfw") } }
    var blurSpoilers: Bool { didSet { d.set(blurSpoilers, forKey: "blurSpoilers") } }
    var autoplay: AutoplayMode { didSet { d.set(autoplay.rawValue, forKey: "autoplay") } }
    var startMuted: Bool { didSet { d.set(startMuted, forKey: "startMuted") } }
    var dataSaver: Bool { didSet { d.set(dataSaver, forKey: "dataSaver") } }
    var hideRead: Bool { didSet { d.set(hideRead, forKey: "hideRead") } }
    var dimRead: Bool { didSet { d.set(dimRead, forKey: "dimRead") } }
    var showFlair: Bool { didSet { d.set(showFlair, forKey: "showFlair") } }
    var showThumbnails: Bool { didSet { d.set(showThumbnails, forKey: "showThumbnails") } }
    var swipeActions: Bool { didSet { d.set(swipeActions, forKey: "swipeActions") } }
    var nextCommentButton: Bool { didSet { d.set(nextCommentButton, forKey: "nextCommentButton") } }
    var collapseAutomod: Bool { didSet { d.set(collapseAutomod, forKey: "collapseAutomod") } }
    var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    var inAppBrowser: Bool { didSet { d.set(inAppBrowser, forKey: "inAppBrowser") } }
    var readerMode: Bool { didSet { d.set(readerMode, forKey: "readerMode") } }
    var requestsPerMinute: Int { didSet { d.set(requestsPerMinute, forKey: "rpm") } }
    var cacheMode: CacheMode { didSet { d.set(cacheMode.rawValue, forKey: "cacheMode") } }
    var source: ImageSource { didSet { d.set(source.rawValue, forKey: "source") } }
    var connection: ConnectionMode { didSet { d.set(connection.rawValue, forKey: "connection") } }
    var apiClientID: String { didSet { d.set(apiClientID, forKey: "apiClientID") } }
    var apiRedirectURI: String { didSet { d.set(apiRedirectURI, forKey: "apiRedirectURI") } }
    var apiUserAgent: String { didSet { d.set(apiUserAgent, forKey: "apiUserAgent") } }
    /// Whether OAuth tokens exist (set at launch and on sign-in/out; not persisted).
    var apiSignedIn = false

    /// Official API mode is in use: selected and signed in.
    var apiActive: Bool { connection == .api && apiSignedIn }

    /// Signed in on reddit.com (verified via /api/me). Mirrors NetworkStatus.signedIn for non-UI code.
    var webSessionSignedIn = false
    /// The web-session route (cookie auth on oauth.reddit.com) is paused until this time after repeated blocks.
    var sessionCooldownUntil = Date.distantPast

    /// Key-free web session route: your reddit.com login used against oauth.reddit.com.
    var sessionRouteActive: Bool { connection != .api && connection != .direct && webSessionSignedIn && Date() >= sessionCooldownUntil }

    /// Full Reddit features available (own API key, or a working web session).
    var fullAccess: Bool { apiActive || sessionRouteActive }

    private init() {
        func e<T: RawRepresentable>(_ k: String, _ def: T) -> T where T.RawValue == String {
            UserDefaults.standard.string(forKey: k).flatMap(T.init(rawValue:)) ?? def
        }
        func b(_ k: String, _ def: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? def }
        theme = e("theme", AppTheme.system)
        accent = e("accent", AccentChoice.orange)
        textSize = e("textSize", TextSize.large)
        layout = e("layout", PostLayout.card)
        twoPane = b("twoPane", true)
        homeSort = e("homeSort", SortOrder.hot)
        commentSort = e("commentSort", CommentSort.confidence)
        nsfw = e("nsfw", NSFWMode.blur)
        blurSpoilers = b("blurSpoilers", true)
        autoplay = e("autoplay", AutoplayMode.always)
        startMuted = b("startMuted", true)
        dataSaver = b("dataSaver", false)
        hideRead = b("hideRead", false)
        dimRead = b("dimRead", true)
        showFlair = b("showFlair", true)
        showThumbnails = b("showThumbnails", true)
        swipeActions = b("swipeActions", true)
        nextCommentButton = b("nextCommentButton", true)
        collapseAutomod = b("collapseAutomod", true)
        haptics = b("haptics", true)
        inAppBrowser = b("inAppBrowser", true)
        readerMode = b("readerMode", false)
        requestsPerMinute = (UserDefaults.standard.object(forKey: "rpm") as? Int) ?? 9
        cacheMode = e("cacheMode", CacheMode.balanced)
        source = e("source", ImageSource.www)
        connection = e("connection", ConnectionMode.automatic)
        apiClientID = UserDefaults.standard.string(forKey: "apiClientID") ?? ""
        apiRedirectURI = UserDefaults.standard.string(forKey: "apiRedirectURI") ?? "qorvex://auth"
        apiUserAgent = UserDefaults.standard.string(forKey: "apiUserAgent") ?? "ios:com.qorvex.reader:v1.0 (by /u/YOUR_USERNAME)"
    }

    func reset() {
        for k in ["theme", "accent", "textSize", "layout", "twoPane", "homeSort", "commentSort", "nsfw", "blurSpoilers", "autoplay",
                  "startMuted", "dataSaver", "hideRead", "dimRead", "showFlair", "showThumbnails", "swipeActions", "nextCommentButton",
                  "collapseAutomod", "haptics", "inAppBrowser", "readerMode", "rpm", "cacheMode", "source", "connection"] {
            d.removeObject(forKey: k)
        }
        let fresh = AppSettings()
        theme = fresh.theme; accent = fresh.accent; textSize = fresh.textSize; layout = fresh.layout; twoPane = fresh.twoPane
        homeSort = fresh.homeSort; commentSort = fresh.commentSort; nsfw = fresh.nsfw; blurSpoilers = fresh.blurSpoilers
        autoplay = fresh.autoplay; startMuted = fresh.startMuted; dataSaver = fresh.dataSaver; hideRead = fresh.hideRead
        dimRead = fresh.dimRead; showFlair = fresh.showFlair; showThumbnails = fresh.showThumbnails; swipeActions = fresh.swipeActions
        nextCommentButton = fresh.nextCommentButton; collapseAutomod = fresh.collapseAutomod; haptics = fresh.haptics
        inAppBrowser = fresh.inAppBrowser; readerMode = fresh.readerMode; requestsPerMinute = fresh.requestsPerMinute
        cacheMode = fresh.cacheMode; source = fresh.source; connection = fresh.connection
    }
}

@MainActor
enum Haptics {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard AppSettings.shared.haptics else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func success() {
        guard AppSettings.shared.haptics else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
