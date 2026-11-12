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
    var sort: SortOrder
    var time: TimeRange = .day
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var generation = 0

    init(source: FeedSource) {
        self.source = source
        sort = source == .home ? AppSettings.shared.homeSort : .hot
    }

    @MainActor
    func load(reset: Bool = false, force: Bool = false) async {
        if loading && !reset { return }
        if done && !reset { return }
        generation += 1
        let gen = generation
        loading = true
        if reset { error = nil; staleNote = nil }
        do {
            let r = try await Reddit.listing(source.path, sort: sort, time: time, after: reset ? nil : after, force: force)
            guard gen == generation else { return }
            if reset { posts = []; seen = []; done = false }
            var new: [Post] = []
            for t in r.value.data.children {
                guard case .post(let p) = t, !seen.contains(p.id) else { continue }
                seen.insert(p.id)
                if Library.shared.shouldShow(p) { new.append(p) }
            }
            posts.append(contentsOf: new)
            after = r.value.data.after
            done = after == nil
            staleNote = r.stale ? "\(r.error?.localizedDescription ?? "Offline") · showing cached from \(Int(r.age / 60)) min ago" : nil
            loading = false
            // Heavily filtered pages: keep going so the list never looks empty.
            if new.count < 5 && !done { await load() }
        } catch {
            guard gen == generation else { return }
            self.error = error.localizedDescription
            loading = false
        }
    }

    func remove(_ id: String) { posts.removeAll { $0.id == id } }
}

struct FeedView: View {
    let source: FeedSource
    @State private var model: FeedModel
    @Environment(Router.self) private var router
    private var settings: AppSettings { .shared }
    private var library: Library { .shared }

    init(source: FeedSource) {
        self.source = source
        _model = State(initialValue: FeedModel(source: source))
    }

    private var isRoot: Bool { source == .home || source == .popular }

    private var filterCount: Int {
        let f = library.filters
        return f.subreddits.count + f.users.count + f.domains.count + f.keywords.count
    }

    var body: some View {
        List {
            if let sub = source.subredditName {
                SubredditHeader(name: sub)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if source == .home && library.subs.isEmpty {
                HintCard(icon: "sparkles", text: "Your Home shows Popular until you join communities. Find some in Search or Library.")
                    .plainRow()
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
        .task { if model.posts.isEmpty && !model.loading { await model.load(reset: true) } }
        .onChange(of: library.subs) { _, _ in if source == .home { Task { await model.load(reset: true) } } }
        .onChange(of: filterCount) { _, _ in
            model.posts.removeAll { !library.shouldShow($0) }
        }
        .onChange(of: library.hidden.count) { _, _ in model.posts.removeAll { library.hidden.contains($0.id) } }
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
                        } label: {
                            Label(s.label, systemImage: model.sort == s ? "checkmark" : s.icon)
                        }
                    }
                }
            } label: {
                Image(systemName: model.sort.icon)
            }
            Menu {
                if let sub = source.subredditName {
                    Button { library.toggleSubscription(sub); Haptics.success() } label: {
                        Label(library.isSubscribed(sub) ? "Leave r/\(sub)" : "Join r/\(sub)", systemImage: library.isSubscribed(sub) ? "minus.circle" : "plus.circle")
                    }
                    Button { router.push(.search(sub: sub)) } label: { Label("Search r/\(sub)", systemImage: "magnifyingglass") }
                    Menu {
                        ForEach(library.feeds) { f in
                            Button {
                                if let i = library.feeds.firstIndex(of: f) {
                                    if library.feeds[i].subs.contains(sub) { library.feeds[i].subs.removeAll { $0 == sub } } else { library.feeds[i].subs.append(sub) }
                                }
                                Presenter.shared.show("Updated \(f.name)")
                            } label: {
                                if f.subs.contains(sub) { Label(f.name, systemImage: "checkmark") } else { Text(f.name) }
                            }
                        }
                        Button { library.feeds.append(CustomFeed(name: "New Feed", subs: [sub])); Presenter.shared.show("Created New Feed") } label: {
                            Label("New Custom Feed", systemImage: "plus")
                        }
                    } label: { Label("Add to Custom Feed", systemImage: "square.stack.3d.up") }
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
                Image(systemName: "ellipsis.circle")
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
