import SwiftUI

enum UserItem: Identifiable {
    case post(Post)
    case comment(Comment)
    var id: String {
        switch self {
        case .post(let p): return "p" + p.id
        case .comment(let c): return "c" + c.id
        }
    }
}

struct UserView: View {
    let name: String
    @State private var user: RedditUser?
    @State private var items: [UserItem] = []
    @State private var after: String?
    @State private var loading = false
    @State private var error: String?
    @State private var tab = "overview"
    @State private var sort: SortOrder = .new
    @Environment(Router.self) private var router
    private var library: Library { .shared }

    var body: some View {
        List {
            header.plainRow()

            ForEach(items) { item in
                Group {
                    switch item {
                    case .post(let p):
                        PostRow(post: p)
                            .contextMenu { PostMenuItems(post: p, router: router) }
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
                .onAppear { if item.id == items.last?.id { Task { await load() } } }
            }
            if loading { ProgressView().frame(maxWidth: .infinity).padding().plainRow() }
            else if let error { ErrorState(message: error) { Task { await load(reset: true) } }.plainRow() }
            else if items.isEmpty { EmptyState(icon: "person", title: "Nothing here").plainRow() }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("u/\(name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: URL(string: "https://www.reddit.com/user/\(name)")!) { Label("Share Profile", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { library.filters.users.append(name); Presenter.shared.show("u/\(name) filtered") } label: {
                        Label("Filter This User", systemImage: "nosign")
                    }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        .refreshable { await load(reset: true, force: true) }
        .task {
            if items.isEmpty { await load(reset: true) }
        }
        .handlesLinks(router)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Avatar(name: name, url: user?.iconURL, size: 84)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            Text(user?.subreddit?.title?.isEmpty == false ? user!.subreddit!.title! : "u/\(name)").font(.title3.bold())
            if let u = user {
                HStack(spacing: 22) {
                    stat((u.link_karma ?? 0).compact, "Post karma")
                    stat((u.comment_karma ?? 0).compact, "Comment karma")
                    if let c = u.created_utc { stat(Date(timeIntervalSince1970: c).ago, "On Reddit") }
                }
                if let d = u.subreddit?.public_description, !d.isEmpty {
                    Text(d).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.headline.monospacedDigit())
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @MainActor private func load(reset: Bool = false, force: Bool = false) async {
        if loading && !reset { return }
        if !reset && after == nil && !items.isEmpty { return }
        loading = true; error = nil
        do {
            let r = try await Reddit.userListing(name, after: reset ? nil : after, force: force)
            if reset { items = [] }
            for t in r.value.data.children {
                switch t {
                case .post(let p): if library.shouldShow(p) { items.append(.post(p)) }
                case .comment(let c): items.append(.comment(c))
                default: break
                }
            }
            after = r.value.data.after
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct UserCommentRow: View {
    let comment: Comment
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = comment.link_title {
                Text(t).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            HStack(spacing: 4) {
                if let s = comment.subreddit { Text("r/\(s)").fontWeight(.medium) }
                Text("· \(comment.created.ago) ·")
                Image(systemName: "arrow.up")
                Text((comment.score ?? 0).compact)
            }
            .font(.caption).foregroundStyle(.secondary)
            MarkdownView(blocks: Markdown.parse(comment.body ?? ""))
                .font(.subheadline)
                .lineLimit(8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
