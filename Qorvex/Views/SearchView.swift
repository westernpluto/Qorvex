import SwiftUI
import Observation

enum SearchScope: String, CaseIterable, Identifiable {
    case posts, communities, people
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

@Observable
final class SearchModel {
    var scope: SearchScope = .posts
    var sort = "relevance"
    var time: TimeRange = .all
    var query = ""
    var posts: [Post] = []
    var subs: [Subreddit] = []
    var users: [RedditUser] = []
    var after: String?
    var loading = false
    var error: String?
    var searched = false
    @ObservationIgnored var generation = 0

    @MainActor
    func run(_ q: String, sub: String?, more: Bool = false) async {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if more && (after == nil || loading) { return }
        generation += 1
        let gen = generation
        if !more { query = q; posts = []; subs = []; users = []; after = nil; Library.shared.addRecent(q) }
        loading = true; error = nil; searched = true
        do {
            let r: Fetched<ListingResponse>
            switch scope {
            case .posts: r = try await Reddit.searchPosts(q, sub: sub, sort: sort, time: time, after: more ? after : nil)
            case .communities: r = try await Reddit.searchSubreddits(q, after: more ? after : nil)
            case .people: r = try await Reddit.searchUsers(q, after: more ? after : nil)
            }
            guard gen == generation else { return }
            for t in r.value.data.children {
                switch t {
                case .post(let p): if Library.shared.shouldShow(p), !posts.contains(p) { posts.append(p) }
                case .subreddit(let s): subs.append(s)
                case .user(let u): users.append(u)
                default: break
                }
            }
            after = r.value.data.after
        } catch {
            if gen == generation { self.error = error.localizedDescription }
        }
        if gen == generation { loading = false }
    }
}

struct SearchView: View {
    var restrictTo: String? = nil
    @State private var text = ""
    @State private var model = SearchModel()
    @State private var sub: String?
    @Environment(Router.self) private var router
    private var library: Library { .shared }

    var body: some View {
        List {
            Picker("Search for", selection: $model.scope) {
                ForEach(SearchScope.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                explore
            } else if !model.searched {
                Section { suggestions }
            } else {
                results
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle(sub.map { "Search r/\($0)" } ?? "Search")
        .navigationBarTitleDisplayMode(restrictTo == nil ? .large : .inline)
        .searchable(text: $text, prompt: sub.map { "Search r/\($0)" } ?? "Posts, communities, people")
        .onSubmit(of: .search) { Task { await model.run(text, sub: sub) } }
        .onChange(of: model.scope) { _, _ in if !text.isEmpty && model.searched { Task { await model.run(text, sub: sub) } } }
        .onChange(of: text) { _, new in if new.isEmpty { model.searched = false } }
        .toolbar {
            if model.scope == .posts {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: Binding(get: { model.sort }, set: { model.sort = $0; Task { await model.run(text, sub: sub) } })) {
                            Label("Relevance", systemImage: "sparkles").tag("relevance")
                            Label("Hot", systemImage: "flame").tag("hot")
                            Label("Top", systemImage: "chart.bar").tag("top")
                            Label("New", systemImage: "clock").tag("new")
                            Label("Most Comments", systemImage: "bubble.left.and.bubble.right").tag("comments")
                        }
                        Picker("Time", selection: Binding(get: { model.time }, set: { model.time = $0; Task { await model.run(text, sub: sub) } })) {
                            ForEach(TimeRange.allCases) { Text($0.label).tag($0) }
                        }
                    } label: { Label("Sort & Filter", systemImage: "line.3.horizontal.decrease.circle") }
                }
            }
        }
        .onAppear { if sub == nil { sub = restrictTo } }
        .handlesLinks(router)
    }

    @ViewBuilder private var suggestions: some View {
        let q = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "r/", with: "")
        if !q.isEmpty {
            if q.range(of: #"^\w{2,21}$"#, options: .regularExpression) != nil {
                NavigationLink(value: Route.feed(.subreddit(q))) { Label("Go to r/\(q)", systemImage: "arrow.right.circle") }
                NavigationLink(value: Route.user(q)) { Label("Go to u/\(q)", systemImage: "person.crop.circle") }
            }
            ForEach(library.sortedSubs.filter { $0.localizedCaseInsensitiveContains(q) }.prefix(6), id: \.self) { s in
                NavigationLink(value: Route.feed(.subreddit(s))) {
                    HStack { Avatar(name: s, size: 24); Text("r/\(s)"); Spacer(); Text("Joined").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Button { Task { await model.run(text, sub: sub) } } label: {
                Label("Search “\(text.trimmingCharacters(in: .whitespaces))”", systemImage: "magnifyingglass")
            }
        }
    }

    @ViewBuilder private var explore: some View {
        if let s = sub {
            Section {
                Button { sub = nil } label: { Label("Searching only r/\(s) — tap to search everywhere", systemImage: "xmark.circle") }
            }
        }
        if !library.recentSearches.isEmpty {
            Section {
                ForEach(library.recentSearches, id: \.self) { q in
                    Button { text = q; Task { await model.run(q, sub: sub) } } label: {
                        Label(q, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                    }
                }
                .onDelete { library.recentSearches.remove(atOffsets: $0) }
            } header: {
                HStack { Text("Recent"); Spacer(); Button("Clear") { library.recentSearches = [] }.font(.footnote) }
            }
        }
        Section("Explore") {
            NavigationLink(value: Route.feed(.all)) { RowIcon(icon: "globe", color: .green, title: "r/all", subtitle: "Everything on Reddit") }
            NavigationLink(value: Route.discover) { RowIcon(icon: "sparkles", color: .purple, title: "Discover Communities", subtitle: "Popular subreddits") }
            NavigationLink(value: Route.feed(.popular)) { RowIcon(icon: "flame.fill", color: .orange, title: "Popular", subtitle: "Trending right now") }
        }
        if !library.subs.isEmpty {
            Section("Your Communities") {
                ForEach(library.sortedSubs.prefix(8), id: \.self) { s in
                    NavigationLink(value: Route.feed(.subreddit(s))) { HStack(spacing: 12) { Avatar(name: s, size: 30); Text("r/\(s)") } }
                }
            }
        }
    }

    @ViewBuilder private var results: some View {
        Section {
            switch model.scope {
            case .posts:
                ForEach(model.posts) { p in
                    PostRow(post: p)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                        .contextMenu { PostMenuItems(post: p, router: router) }
                        .onAppear { if p.id == model.posts.last?.id { Task { await model.run(text, sub: sub, more: true) } } }
                }
            case .communities:
                ForEach(model.subs) { s in
                    NavigationLink(value: Route.feed(.subreddit(s.display_name))) { SubredditRow(sub: s) }
                        .onAppear { if s.display_name == model.subs.last?.display_name { Task { await model.run(text, sub: sub, more: true) } } }
                }
            case .people:
                ForEach(model.users, id: \.name) { u in
                    NavigationLink(value: Route.user(u.name)) { UserRow(user: u) }
                        .onAppear { if u.name == model.users.last?.name { Task { await model.run(text, sub: sub, more: true) } } }
                }
            }
            if model.loading {
                ProgressView().frame(maxWidth: .infinity).padding().listRowBackground(Color.clear)
            } else if let e = model.error {
                ErrorState(message: e) { Task { await model.run(text, sub: sub) } }.listRowBackground(Color.clear)
            } else if model.posts.isEmpty && model.subs.isEmpty && model.users.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "No results", message: "Nothing matched “\(model.query)”.").listRowBackground(Color.clear)
            }
        }
    }
}

struct RowIcon: View {
    let icon: String
    let color: Color
    let title: String
    var subtitle: String? = nil
    var detail: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
    }
}
