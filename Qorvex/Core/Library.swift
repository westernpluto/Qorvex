import Foundation
import Observation

struct SavedPost: Codable, Identifiable {
    var id: String { post.id }
    let post: Post
    let savedAt: Date
}

struct HistoryItem: Codable, Identifiable {
    let id: String
    let title: String
    let subreddit: String
    let readAt: Date
}

struct CustomFeed: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var subs: [String]
}

struct Filters: Codable {
    var keywords: [String] = []
    var subreddits: [String] = []
    var users: [String] = []
    var domains: [String] = []
}

/// Everything the user keeps locally: communities, saved posts, history, filters, custom feeds.
@Observable
final class Library {
    static let shared = Library()

    var subs: [String] { didSet { persist() } }
    var saved: [SavedPost] { didSet { persist() } }
    var history: [HistoryItem] { didSet { persistSoon() } }
    var hidden: Set<String> { didSet { persistSoon() } }
    var filters: Filters { didSet { persist() } }
    var feeds: [CustomFeed] { didSet { persist() } }
    var recentSearches: [String] { didSet { persist() } }

    @ObservationIgnored private var readIDs: Set<String> = []
    @ObservationIgnored private var pending: DispatchWorkItem?

    private struct Snapshot: Codable {
        var subs: [String]
        var saved: [SavedPost]
        var history: [HistoryItem]
        var hidden: [String]
        var filters: Filters
        var feeds: [CustomFeed]
        var recentSearches: [String]?
    }

    static let defaultSubs = ["pics", "technology", "science", "worldnews", "todayilearned", "space", "aww", "EarthPorn", "dataisbeautiful", "movies", "gaming", "interestingasfuck"]

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }

    private init() {
        let snap = (try? Data(contentsOf: Library.fileURL)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        subs = snap?.subs ?? []
        saved = snap?.saved ?? []
        history = snap?.history ?? []
        hidden = Set(snap?.hidden ?? [])
        filters = snap?.filters ?? Filters()
        feeds = snap?.feeds ?? []
        recentSearches = snap?.recentSearches ?? []
        readIDs = Set(history.map(\.id))
    }

    private func snapshot() -> Snapshot {
        Snapshot(subs: subs, saved: saved, history: history, hidden: Array(hidden.suffix(4000)), filters: filters, feeds: feeds, recentSearches: recentSearches)
    }

    private func persist() {
        pending?.cancel()
        let data = try? JSONEncoder().encode(snapshot())
        DispatchQueue.global(qos: .utility).async { try? data?.write(to: Library.fileURL, options: .atomic) }
    }

    private func persistSoon() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: Communities
    var sortedSubs: [String] { subs.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
    func isSubscribed(_ name: String) -> Bool { subs.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
    @discardableResult
    func toggleSubscription(_ name: String) -> Bool {
        if isSubscribed(name) { subs.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }; return false }
        subs.append(name); return true
    }

    // MARK: Saved
    func isSaved(_ id: String) -> Bool { saved.contains { $0.id == id } }
    @discardableResult
    func toggleSave(_ post: Post) -> Bool {
        if isSaved(post.id) { saved.removeAll { $0.id == post.id }; return false }
        saved.insert(SavedPost(post: post, savedAt: Date()), at: 0); return true
    }

    // MARK: History
    func isRead(_ id: String) -> Bool { readIDs.contains(id) }
    func markRead(_ post: Post) {
        history.removeAll { $0.id == post.id }
        history.insert(HistoryItem(id: post.id, title: post.title, subreddit: post.subreddit, readAt: Date()), at: 0)
        if history.count > 1500 { history.removeLast(history.count - 1500) }
        readIDs.insert(post.id)
    }
    func clearHistory() { history = []; readIDs = [] }

    // MARK: Hidden & filters
    func hide(_ id: String) { hidden.insert(id) }
    func unhide(_ id: String) { hidden.remove(id) }

    func shouldShow(_ p: Post) -> Bool {
        if hidden.contains(p.id) { return false }
        let s = AppSettings.shared
        if p.over_18 == true && s.nsfw == .hide { return false }
        if s.hideRead && isRead(p.id) { return false }
        let lc = { (x: String?) in (x ?? "").lowercased() }
        if filters.subreddits.contains(where: { lc($0) == lc(p.subreddit) }) { return false }
        if filters.users.contains(where: { lc($0) == lc(p.author) }) { return false }
        if let d = p.domain, filters.domains.contains(where: { !$0.isEmpty && lc(d).hasSuffix(lc($0)) }) { return false }
        let t = p.title.lowercased()
        if filters.keywords.contains(where: { !$0.isEmpty && t.contains($0.lowercased()) }) { return false }
        return true
    }

    // MARK: Searches
    func addRecent(_ q: String) {
        recentSearches.removeAll { $0 == q }
        recentSearches.insert(q, at: 0)
        if recentSearches.count > 12 { recentSearches.removeLast() }
    }

    // MARK: Backup
    func exportData() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(snapshot())) ?? Data()
    }

    func importData(_ data: Data) throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let s = try dec.decode(Snapshot.self, from: data)
        subs = s.subs; saved = s.saved; history = s.history; hidden = Set(s.hidden)
        filters = s.filters; feeds = s.feeds; recentSearches = s.recentSearches ?? []
        readIDs = Set(history.map(\.id))
    }
}
