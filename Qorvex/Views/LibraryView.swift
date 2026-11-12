import SwiftUI

struct LibraryView: View {
    @Environment(Router.self) private var router
    @State private var addingSub = false
    @State private var newSub = ""
    @State private var editingFeed: CustomFeed?
    private var library: Library { .shared }

    var body: some View {
        List {
            Section {
                NavigationLink(value: Route.saved) { RowIcon(icon: "bookmark.fill", color: .accentColor, title: "Saved", detail: "\(library.saved.count)") }
                NavigationLink(value: Route.history) { RowIcon(icon: "clock.fill", color: .blue, title: "History", detail: "\(library.history.count)") }
                NavigationLink(value: Route.discover) { RowIcon(icon: "sparkles", color: .purple, title: "Discover Communities") }
                NavigationLink(value: Route.feed(.all)) { RowIcon(icon: "globe", color: .green, title: "r/all") }
            }

            Section {
                ForEach(library.feeds) { f in
                    NavigationLink(value: Route.feed(.custom(f.id))) {
                        RowIcon(icon: "square.stack.3d.up.fill", color: .orange, title: f.name, subtitle: f.subs.isEmpty ? "Empty" : f.subs.map { "r/\($0)" }.joined(separator: ", "))
                    }
                    .swipeActions {
                        Button(role: .destructive) { library.feeds.removeAll { $0.id == f.id } } label: { Label("Delete", systemImage: "trash") }
                        Button { editingFeed = f } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                    }
                    .contextMenu {
                        Button { editingFeed = f } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { library.feeds.removeAll { $0.id == f.id } } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                Button { editingFeed = CustomFeed(name: "", subs: []) } label: { Label("New Custom Feed", systemImage: "plus.circle.fill") }
            } header: {
                Text("Custom Feeds")
            } footer: {
                Text("Combine communities into your own feeds.")
            }

            Section {
                if library.subs.isEmpty {
                    Text("No communities yet. Search or browse Discover to join some.").foregroundStyle(.secondary)
                }
                ForEach(library.sortedSubs, id: \.self) { s in
                    NavigationLink(value: Route.feed(.subreddit(s))) {
                        HStack(spacing: 12) { Avatar(name: s, size: 30); Text("r/\(s)") }
                    }
                    .swipeActions {
                        Button(role: .destructive) { library.toggleSubscription(s) } label: { Label("Leave", systemImage: "minus.circle") }
                    }
                }
            } header: {
                HStack {
                    Text("Communities · \(library.subs.count)")
                    Spacer()
                    Button { addingSub = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { addingSub = true } label: { Label("Join Community", systemImage: "plus.circle") }
            }
        }
        .alert("Join a Community", isPresented: $addingSub) {
            TextField("subreddit name", text: $newSub)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Join") {
                let n = newSub.replacingOccurrences(of: "r/", with: "").trimmingCharacters(in: .whitespaces)
                if n.range(of: #"^\w{2,21}$"#, options: .regularExpression) != nil {
                    if !library.isSubscribed(n) { library.toggleSubscription(n) }
                    Presenter.shared.show("Joined r/\(n)")
                } else { Presenter.shared.show("That doesn't look like a subreddit") }
                newSub = ""
            }
            Button("Cancel", role: .cancel) { newSub = "" }
        }
        .sheet(item: $editingFeed) { f in FeedEditor(feed: f) }
    }
}

struct FeedEditor: View {
    @State var feed: CustomFeed
    @State private var subsText: String
    @Environment(\.dismiss) private var dismiss
    private var library: Library { .shared }

    init(feed: CustomFeed) {
        _feed = State(initialValue: feed)
        _subsText = State(initialValue: feed.subs.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("e.g. Tech", text: $feed.name) }
                Section {
                    TextEditor(text: $subsText)
                        .frame(minHeight: 180)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: { Text("Communities") } footer: { Text("One per line, without “r/”.") }
                if !library.subs.isEmpty {
                    Section("Add From Your Communities") {
                        ForEach(library.sortedSubs, id: \.self) { s in
                            let lines = parsed
                            Button {
                                if lines.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) {
                                    subsText = lines.filter { $0.caseInsensitiveCompare(s) != .orderedSame }.joined(separator: "\n")
                                } else { subsText = (lines + [s]).joined(separator: "\n") }
                            } label: {
                                HStack {
                                    Avatar(name: s, size: 24); Text("r/\(s)").foregroundStyle(.primary); Spacer()
                                    if lines.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(feed.name.isEmpty ? "New Feed" : feed.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        feed.subs = parsed
                        if feed.name.isEmpty { feed.name = "My Feed" }
                        if let i = library.feeds.firstIndex(where: { $0.id == feed.id }) { library.feeds[i] = feed } else { library.feeds.append(feed) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var parsed: [String] {
        subsText.components(separatedBy: CharacterSet(charactersIn: "\n, +")).map { $0.replacingOccurrences(of: "r/", with: "").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
