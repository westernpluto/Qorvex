import SwiftUI

/// Saved posts from the Reddit account (paged).
@Observable
final class AccountSavedModel {
    var items: [UserItem] = []
    var after: String?
    var loading = false
    var error: String?
    var loaded = false

    @MainActor
    func load(reset: Bool = false, force: Bool = false) async {
        guard NetworkStatus.shared.signedIn, let name = NetworkStatus.shared.username else { return }
        if loading || (!reset && loaded && after == nil) { return }
        loading = true; error = nil
        do {
            let r = try await Reddit.userSaved(name, after: reset ? nil : after, force: force)
            if reset { items = [] }
            for t in r.value.data.children {
                switch t {
                case .post(let p): items.append(.post(p))
                case .comment(let c): items.append(.comment(c))
                default: break
                }
            }
            after = r.value.data.after
            loaded = true
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

/// The Saved tab: your saved posts and reading history.
struct SavedTab: View {
    enum Section: String, CaseIterable { case saved = "Saved", history = "History" }
    @State private var section: Section = .saved
    @State private var account = AccountSavedModel()
    @State private var confirmClear = false
    @Environment(Router.self) private var router
    private var library: Library { .shared }

    var body: some View {
        List {
            Picker("", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .plainRow()

            switch section {
            case .saved: savedRows
            case .history: historyRows
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle(section.rawValue)
        .toolbar {
            if section == .history {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmClear = true } label: { Label("Clear History", systemImage: "trash") }
                        .disabled(library.history.isEmpty)
                }
            }
        }
        .confirmationDialog("Clear reading history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { library.clearHistory() }
        }
        .refreshable { await account.load(reset: true, force: true) }
        .task { if !account.loaded { await account.load(reset: true) } }
        .onChange(of: NetworkStatus.shared.username) { _, _ in Task { await account.load(reset: true) } }
    }

    @ViewBuilder private var savedRows: some View {
        if !NetworkStatus.shared.signedIn {
            SignInBanner().plainRow()
            localSavedRows
        } else if account.items.isEmpty {
            if account.loading {
                ProgressView().frame(maxWidth: .infinity).padding(30).plainRow()
            } else if let e = account.error {
                ErrorState(message: e) { Task { await account.load(reset: true) } }.plainRow()
            } else {
                EmptyState(icon: "bookmark", title: "Nothing saved", message: "Posts you save on Reddit or here show up in this list.").plainRow()
            }
        } else {
            ForEach(account.items) { item in
                Group {
                    switch item {
                    case .post(let p):
                        PostRow(post: p).contextMenu { PostMenuItems(post: p, router: router) }
                    case .comment(let c):
                        UserCommentRow(comment: c)
                            .contentShape(Rectangle())
                            .onTapGesture { if let pid = c.postID { router.open(PostRef(id: pid, commentID: c.id)) } }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .onAppear { if item.id == account.items.last?.id { Task { await account.load() } } }
            }
            if account.loading { ProgressView().frame(maxWidth: .infinity).padding().plainRow() }
        }
    }

    @ViewBuilder private var localSavedRows: some View {
        ForEach(library.saved) { s in
            PostRow(post: s.post)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions { Button(role: .destructive) { library.toggleSave(s.post) } label: { Label("Unsave", systemImage: "bookmark.slash") } }
                .contextMenu { PostMenuItems(post: s.post, router: router) }
        }
    }

    @ViewBuilder private var historyRows: some View {
        if library.history.isEmpty {
            EmptyState(icon: "clock", title: "No history", message: "Posts you open show up here.").plainRow()
        }
        ForEach(library.history.prefix(400)) { h in
            Button { router.open(PostRef(id: h.id)) } label: {
                HStack(spacing: 12) {
                    Avatar(name: h.subreddit, url: library.icon(for: h.subreddit), size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                        Text("r/\(h.subreddit) · \(h.readAt.ago) ago").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
        }
    }
}

struct DiscoverView: View {
    /// Built in, so browsing costs no requests (Reddit blocks its community directory for apps).
    static let categories: [(String, String, [String])] = [
        ("Popular", "flame.fill", ["pics", "funny", "AskReddit", "gaming", "worldnews", "todayilearned", "movies", "aww", "Music", "memes"]),
        ("News & Science", "newspaper.fill", ["news", "worldnews", "science", "space", "technology", "Futurology", "dataisbeautiful", "explainlikeimfive"]),
        ("Tech", "cpu.fill", ["apple", "iphone", "ios", "programming", "swift", "gadgets", "hardware", "MachineLearning"]),
        ("Beautiful", "photo.fill", ["EarthPorn", "itookapicture", "CityPorn", "SpacePorn", "AbandonedPorn", "MostBeautiful"]),
        ("Interesting", "sparkles", ["interestingasfuck", "Damnthatsinteresting", "nextfuckinglevel", "BeAmazed", "mildlyinteresting", "oddlysatisfying"]),
        ("Entertainment", "tv.fill", ["television", "books", "Games", "NintendoSwitch", "PS5", "anime", "comics"]),
        ("Lifestyle", "leaf.fill", ["food", "Cooking", "fitness", "travel", "DIY", "GetMotivated", "LifeProTips", "personalfinance"]),
        ("Sports", "sportscourt.fill", ["sports", "nba", "nfl", "soccer", "formula1", "baseball"]),
    ]

    var body: some View {
        List {
            ForEach(Self.categories, id: \.0) { cat in
                Section {
                    ForEach(cat.2, id: \.self) { name in
                        NavigationLink(value: Route.feed(.subreddit(name))) {
                            HStack(spacing: 12) {
                                Avatar(name: name, size: 34)
                                Text("r/\(name)").font(.subheadline.weight(.semibold))
                                Spacer()
                                JoinButton(name: name)
                            }
                        }
                    }
                } header: {
                    Label(cat.0, systemImage: cat.1)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Discover")
    }
}

/// The Home tab's list: Home, Popular, All, then your communities, all in one place.
struct CommunitiesView: View {
    @State private var filter = ""
    @Environment(Router.self) private var router
    private var library: Library { .shared }

    private var subs: [String] {
        let all = library.sortedSubs
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(f) }
    }

    var body: some View {
        List {
            // Plain in-list filter (no system search UI, which can float over the window).
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                TextField("Filter communities", text: $filter)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if filter.isEmpty {
                Section {
                    feedRow(.home, title: "Home", subtitle: "Your front page", icon: "house.fill", color: .accentColor)
                    feedRow(.popular, title: "Popular", subtitle: "Trending across Reddit", icon: "flame.fill", color: .orange)
                    feedRow(.all, title: "All", subtitle: "Everything", icon: "globe", color: .green)
                }
                .listRowBackground(Color.cardBackground)
            }

            Section {
                if !NetworkStatus.shared.signedIn && library.subs.isEmpty {
                    SignInBanner()
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowBackground(Color.clear)
                } else if subs.isEmpty {
                    Text(filter.isEmpty ? "You haven't joined any communities yet." : "No matches")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.cardBackground)
                }
                ForEach(subs, id: \.self) { s in
                    NavigationLink(value: Route.feed(.subreddit(s))) {
                        HStack(spacing: 14) {
                            Avatar(name: s, url: library.icon(for: s), size: 32)
                            Text(s)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(minHeight: 44)
                    }
                    .listRowBackground(Color.cardBackground)
                    .contextMenu {
                        Button(role: .destructive) {
                            library.toggleSubscription(s)
                            Task { try? await RedditClient.shared.subscribe(s, join: false) }
                        } label: { Label("Leave r/\(s)", systemImage: "minus.circle") }
                    }
                }
            } header: {
                if !library.subs.isEmpty {
                    Text("Your Communities").textCase(nil).font(.footnote.weight(.semibold))
                }
            }

            if filter.isEmpty {
                Section {
                    NavigationLink(value: Route.discover) {
                        HStack(spacing: 14) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 32, height: 32)
                            Text("Discover Communities").font(.body.weight(.medium))
                        }
                        .frame(minHeight: 44)
                    }
                    .listRowBackground(Color.cardBackground)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("Feeds")
    }

    private func feedRow(_ src: FeedSource, title: String, subtitle: String, icon: String, color: Color) -> some View {
        NavigationLink(value: Route.feed(src)) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(color.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(minHeight: 48)
        }
    }
}
