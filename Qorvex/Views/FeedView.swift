import SwiftUI
import Observation

@Observable
final class FeedModel {
    let source: FeedSource
    var posts: [Post] = []
    var after: String?
    var loading = false
    var error: String?
    var staleNote: String?
    var done = false
    var sort: SortOrder = .hot
    var time: TimeRange = .day
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var generation = 0
    // Multi-community feeds (Home, custom feeds): Reddit won't serve r/a+b, so load a few
    // communities' front pages at a time and merge them.
    @ObservationIgnored private var cursor = 0
    @ObservationIgnored private var subAfter: [String: String] = [:]
    @ObservationIgnored private var exhausted = Set<String>()
    static let batchSize = 3

    init(source: FeedSource) {
        self.source = source
    }

    /// Communities to merge, or nil for a single-page feed.
    private var mergedSubs: [String]? {
        if AppSettings.shared.fullAccess { return nil } // oauth.reddit.com serves r/a+b directly
        switch source {
        case .home:
            let s = Library.shared.subs
            return s.isEmpty ? nil : s
        case .custom(let id):
            let s = Library.shared.feeds.first { $0.id == id }?.subs ?? []
            return s.isEmpty ? nil : s
        default:
            return nil
        }
    }

    private var singlePath: String {
        switch source {
        case .custom where AppSettings.shared.fullAccess: return source.path
        case .home, .custom: return "r/popular"
        default: return source.path
        }
    }

    @MainActor
    func load(reset: Bool = false, force: Bool = false) async {
        if loading && !reset { return }
        if done && !reset { return }
        generation += 1
        let gen = generation
        loading = true
        if reset {
            error = nil; staleNote = nil
            cursor = 0; subAfter = [:]; exhausted = []
        }
        // Signed out: show example posts and send nothing to Reddit.
        if !Self.hasAccount {
            posts = SampleData.posts(for: source)
            seen = Set(posts.map(\.id))
            after = nil; done = true; loading = false
            return
        }
        // Signed in: Home is the account's own front page (your Reddit subscriptions, Reddit's order).
        if source == .home && (NetworkStatus.shared.signedIn || AppSettings.shared.fullAccess) && !Self.frontPageBlocked {
            if let e = await loadSingle(path: "", reset: reset, force: force, gen: gen) {
                if case RedditError.blocked(_) = e { Self.frontPageBlocked = true }
                else if case RedditError.loginRequired = e { Self.frontPageBlocked = true }
                else if case RedditError.decoding = e { Self.frontPageBlocked = true }
                else { return }
                // Fall back to merging the communities saved in Qorvex.
                error = nil
                loading = true
                cursor = 0; subAfter = [:]; exhausted = []
            } else { return }
        }
        if let subs = mergedSubs {
            await loadMerged(subs, reset: reset, force: force, gen: gen)
        } else {
            _ = await loadSingle(path: singlePath, reset: reset, force: force, gen: gen)
        }
    }

    @MainActor static var hasAccount: Bool { NetworkStatus.shared.signedIn || AppSettings.shared.apiActive }

    /// Set once Reddit refuses the signed-in front page, so we don't keep asking this session.
    static var frontPageBlocked = false

    @MainActor var usingFrontPage: Bool { source == .home && (NetworkStatus.shared.signedIn || AppSettings.shared.fullAccess) && !Self.frontPageBlocked }

    @MainActor @discardableResult
    private func loadSingle(path: String, reset: Bool, force: Bool, gen: Int) async -> Error? {
        do {
            let r = try await Reddit.listing(path, sort: sort, time: time, after: reset ? nil : after, force: force)
            guard gen == generation else { return nil }
            if reset { posts = []; seen = []; done = false }
            let new = accept(r.value.data.children)
            posts.append(contentsOf: new)
            after = r.value.data.after
            done = after == nil
            staleNote = r.stale ? "\(r.error?.localizedDescription ?? "Offline") · showing cached from \(Int(r.age / 60)) min ago" : nil
            loading = false
            if new.count < 5 && !done { await load() }
            return nil
        } catch {
            guard gen == generation else { return nil }
            self.error = error.localizedDescription
            loading = false
            return error
        }
    }

    @MainActor
    private func loadMerged(_ subs: [String], reset: Bool, force: Bool, gen: Int) async {
        // Pick the next few communities that still have pages, round-robin.
        var batch: [String] = []
        var scanned = 0
        while batch.count < Self.batchSize && scanned < subs.count {
            let s = subs[cursor % subs.count]
            cursor += 1
            scanned += 1
            if !exhausted.contains(s) && !batch.contains(s) { batch.append(s) }
        }
        if batch.isEmpty {
            if reset { posts = []; seen = [] }
            done = true; loading = false
            return
        }
        var collected: [Post] = []
        var firstError: Error?
        var anyStale = false
        for sub in batch {
            do {
                let r = try await Reddit.listing("r/\(sub)", sort: .hot, time: time, after: subAfter[sub], force: force)
                guard gen == generation else { return }
                if r.stale { anyStale = true }
                for t in r.value.data.children { if case .post(let p) = t { collected.append(p) } }
                if let a = r.value.data.after { subAfter[sub] = a } else { exhausted.insert(sub) }
            } catch {
                guard gen == generation else { return }
                if firstError == nil { firstError = error }
                // Stop early on blocks/login walls so we don't keep knocking.
                if case RedditError.blocked(_) = error { break }
                if case RedditError.loginRequired = error { break }
                if case RedditError.rateLimited = error { break }
                exhausted.insert(sub)
            }
        }
        if reset { posts = []; seen = []; done = false }
        // Merge the batch by a simple "hot" score so communities interleave naturally.
        let now = Date().timeIntervalSince1970
        collected.sort { a, b in
            func hot(_ p: Post) -> Double {
                let ageHours = max(0, (now - p.created_utc) / 3600)
                return Double(max(p.score ?? 0, 0) + 1) / pow(ageHours + 2, 1.5)
            }
            return hot(a) > hot(b)
        }
        let new = accept(collected.map { Thing.post($0) })
        posts.append(contentsOf: new)
        done = exhausted.count >= Set(subs).count
        staleNote = anyStale ? "Some communities are showing cached posts" : nil
        if new.isEmpty, let e = firstError, posts.isEmpty { self.error = e.localizedDescription }
        loading = false
    }

    private func accept(_ things: [Thing]) -> [Post] {
        var new: [Post] = []
        for t in things {
            guard case .post(let p) = t, !seen.contains(p.id) else { continue }
            seen.insert(p.id)
            if let icon = p.sr_detail?.iconURL { Library.shared.learnIcon(p.subreddit, icon) }
            if Library.shared.shouldShow(p) { new.append(p) }
        }
        return new
    }

    func remove(_ id: String) { posts.removeAll { $0.id == id } }
}

struct FeedView: View {
    let source: FeedSource
    var switcher: Binding<FeedSource>? = nil
    @State private var model: FeedModel
    @Environment(Router.self) private var router
    private var settings: AppSettings { .shared }
    private var library: Library { .shared }

    init(source: FeedSource, switcher: Binding<FeedSource>? = nil) {
        self.source = source
        self.switcher = switcher
        _model = State(initialValue: FeedModel(source: source))
    }

    private var isRoot: Bool { source == .home }

    private var filterCount: Int {
        let f = library.filters
        return f.subreddits.count + f.users.count + f.domains.count + f.keywords.count
    }

    var body: some View {
        List {
            if let sub = source.subredditName {
                SubredditHeader(name: sub, detail: model.posts.first?.sr_detail, feedLoaded: !model.posts.isEmpty || model.done)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if !FeedModel.hasAccount {
                SignInBanner().plainRow()
            }
            if source == .home && model.usingFrontPage && model.posts.isEmpty == false {
                Label("Your Reddit front page", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary).plainRow()
            }
            if let note = model.staleNote {
                StaleBanner(text: note).plainRow()
            }
            ForEach(model.posts) { post in
                FeedRow(post: post, showSubreddit: source.subredditName == nil, model: model)
            }
            footer.plainRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .toolbar { toolbar }
        .refreshable { await model.load(reset: true, force: true) }
        .task {
            if model.posts.isEmpty && !model.loading { await model.load(reset: true) }
            if isRoot, LaunchArgs.openSample, let first = model.posts.first {
                LaunchArgs.openSample = false
                router.open(first)
            }
        }
        .onChange(of: library.subs) { _, _ in if source == .home && !model.usingFrontPage { Task { await model.load(reset: true) } } }
        .onChange(of: NetworkStatus.shared.signedIn) { _, _ in reloadIfMulti() }
        .onChange(of: AppSettings.shared.fullAccess) { _, _ in reloadIfMulti() }
        .onChange(of: filterCount) { _, _ in
            model.posts.removeAll { !library.shouldShow($0) }
        }
        .onChange(of: library.hidden.count) { _, _ in model.posts.removeAll { library.hidden.contains($0.id) } }
    }

    /// Reload when sign-in or full access changes (signed-out feeds show examples).
    private func reloadIfMulti() {
        Task { await model.load(reset: true) }
    }

    @ViewBuilder private var footer: some View {
        if model.loading {
            if model.posts.isEmpty { SkeletonFeed() } else {
                ProgressView().frame(maxWidth: .infinity).padding(24)
            }
        } else if let e = model.error {
            ErrorState(message: e) { Task { await model.load(reset: model.posts.isEmpty) } }
        } else if model.posts.isEmpty && model.done {
            EmptyState(icon: "tray", title: "No posts", message: "Nothing to show here right now.")
        } else if model.done {
            Image(systemName: "checkmark.circle").foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(28)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                if Reddit.sortsAvailable {
                    ForEach(SortOrder.allCases) { s in
                        if s.needsTime {
                            Menu {
                                ForEach(TimeRange.allCases) { t in
                                    Button {
                                        model.sort = s; model.time = t
                                        Task { await model.load(reset: true) }
                                    } label: {
                                        if model.sort == s && model.time == t { Label(t.label, systemImage: "checkmark") } else { Text(t.label) }
                                    }
                                }
                            } label: { Label(model.sort == s ? "\(s.label) · \(model.time.label)" : s.label, systemImage: s.icon) }
                        } else {
                            Button {
                                model.sort = s
                                Task { await model.load(reset: true) }
                            } label: { Label(s.label, systemImage: model.sort == s ? "checkmark" : s.icon) }
                        }
                    }
                } else {
                    Button { } label: { Label("Hot", systemImage: "checkmark") }
                    Section("Other sorts need signing in to Reddit or an API key (Settings)") {
                        ForEach(SortOrder.allCases.filter { $0 != .hot }) { s in
                            Button { } label: { Label(s.label, systemImage: s.icon) }.disabled(true)
                        }
                    }
                }
            } label: {
                Label("Sort: \(model.sort.label)", systemImage: model.sort.icon)
            }
            Menu {
                if let sub = source.subredditName {
                    Button { library.toggleSubscription(sub); Haptics.success() } label: {
                        Label(library.isSubscribed(sub) ? "Leave r/\(sub)" : "Join r/\(sub)", systemImage: library.isSubscribed(sub) ? "minus.circle" : "plus.circle")
                    }
                    Button { router.push(.search(sub: sub)) } label: { Label("Search r/\(sub)", systemImage: "magnifyingglass") }
                    ShareLink(item: URL(string: "https://www.reddit.com/r/\(sub)")!) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { library.filters.subreddits.append(sub); Presenter.shared.show("Filtered from your feeds") } label: {
                        Label("Filter from Home & Popular", systemImage: "nosign")
                    }
                }
                Picker("Layout", selection: Binding(get: { settings.layout }, set: { settings.layout = $0 })) {
                    ForEach(PostLayout.allCases) { Label($0.label, systemImage: $0 == .card ? "rectangle.grid.1x2" : "list.bullet").tag($0) }
                }
                Button { Task { await model.load(reset: true, force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

extension View {
    func plainRow() -> some View {
        listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// One post in a feed list, with swipe actions, context menu and infinite-scroll trigger.
private struct FeedRow: View {
    let post: Post
    let showSubreddit: Bool
    let model: FeedModel
    @Environment(Router.self) private var router
    private var settings: AppSettings { .shared }
    private var library: Library { .shared }

    var body: some View {
        let isCard = settings.layout == .card
        let rowBackground: Color = isCard ? Color.clear : Color.cardBackground
        PostRow(post: post, showSubreddit: showSubreddit)
            .padding(.horizontal, isCard ? 12 : 0)
            .padding(.vertical, isCard ? 5 : 0)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(isCard ? .hidden : .visible)
            .listRowBackground(rowBackground)
            .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingActions }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { trailingActions }
            .contextMenu { PostMenuItems(post: post, router: router) }
            .onAppear(perform: loadMoreIfNeeded)
    }

    @ViewBuilder private var leadingActions: some View {
        if settings.swipeActions {
            Button(action: save) {
                Label(library.isSaved(post.id) ? "Unsave" : "Save", systemImage: "bookmark.fill")
            }
            .tint(.accentColor)
        }
    }

    @ViewBuilder private var trailingActions: some View {
        if settings.swipeActions {
            Button(action: hide) { Label("Hide", systemImage: "eye.slash.fill") }
                .tint(.gray)
            ShareLink(item: post.webURL) { Label("Share", systemImage: "square.and.arrow.up") }
                .tint(.blue)
        }
    }

    private func save() {
        let on = library.toggleSave(post)
        Haptics.success()
        Presenter.shared.show(on ? "Saved" : "Unsaved")
    }

    private func hide() {
        library.hide(post.id)
        withAnimation { model.remove(post.id) }
        Haptics.tap(.medium)
    }

    private func loadMoreIfNeeded() {
        let posts = model.posts
        let trigger = posts.count > 6 ? posts[posts.count - 7].id : posts.last?.id
        if post.id == trigger || post.id == posts.last?.id {
            Task { await model.load() }
        }
    }
}
