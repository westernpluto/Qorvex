import SwiftUI

/// The Saved tab: saved posts and reading history, nothing else.
struct SavedTab: View {
    enum Section: String, CaseIterable { case saved = "Saved", history = "History" }
    @State private var section: Section = .saved

    var body: some View {
        Group {
            switch section {
            case .saved: SavedView()
            case .history: HistoryView()
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.bar)
        }
    }
}

struct SavedView: View {
    @Environment(Router.self) private var router
    private var library: Library { .shared }

    var body: some View {
        List {
            if library.saved.isEmpty {
                EmptyState(icon: "bookmark", title: "Nothing saved", message: "Swipe right on a post to save it. Saved posts work offline.").plainRow()
            }
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("Saved")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct HistoryView: View {
    @Environment(Router.self) private var router
    @State private var confirm = false
    private var library: Library { .shared }

    var body: some View {
        List {
            if library.history.isEmpty {
                EmptyState(icon: "clock", title: "No history", message: "Posts you open show up here.").plainRow()
            }
            ForEach(library.history.prefix(400)) { h in
                Button { router.open(PostRef(id: h.id)) } label: {
                    HStack(spacing: 12) {
                        Avatar(name: h.subreddit, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                            Text("r/\(h.subreddit) · \(h.readAt.ago) ago").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirm = true } label: { Label("Clear History", systemImage: "trash") }.disabled(library.history.isEmpty)
            }
        }
        .confirmationDialog("Clear reading history?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { library.clearHistory() }
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
