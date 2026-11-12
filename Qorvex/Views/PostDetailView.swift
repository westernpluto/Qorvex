import SwiftUI
import Observation

struct CommentNode: Identifiable {
    enum Kind {
        case comment(Comment, [MDBlock])
        case more(More)
        case continueThread(String)
    }
    let id: String
    let kind: Kind
    let depth: Int
    var descendants: Int = 0
}

@Observable
final class CommentsModel {
    let postID: String
    let commentID: String?
    var post: Post?
    var selfBlocks: [MDBlock] = []
    var nodes: [CommentNode] = []
    var collapsed: Set<String> = []
    var loading = false
    var loaded = false
    var error: String?
    var staleNote: String?
    var sort: CommentSort = AppSettings.shared.commentSort
    var loadingMore: Set<String> = []

    init(ref: PostRef) {
        postID = ref.id
        commentID = ref.commentID
        if let p = ref.preview { setPost(p) }
    }

    private func setPost(_ p: Post) {
        post = p
        let text = p.selftext ?? p.crosspost_parent_list?.first?.selftext ?? ""
        selfBlocks = text.isEmpty ? [] : Markdown.parse(text)
    }

    var visible: [CommentNode] {
        var out: [CommentNode] = []
        out.reserveCapacity(nodes.count)
        var skipBelow: Int? = nil
        for n in nodes {
            if let d = skipBelow { if n.depth > d { continue } else { skipBelow = nil } }
            out.append(n)
            if collapsed.contains(n.id) { skipBelow = n.depth }
        }
        return out
    }

    static func flatten(_ things: [Thing], depth: Int, into out: inout [CommentNode]) -> Int {
        var total = 0
        for t in things {
            switch t {
            case .comment(let c):
                let idx = out.count
                out.append(CommentNode(id: c.id, kind: .comment(c, Markdown.parse(c.body ?? "")), depth: depth))
                let kids = flatten(c.replies?.children ?? [], depth: depth + 1, into: &out)
                out[idx].descendants = kids
                total += 1 + kids
            case .more(let m):
                if m.children.isEmpty || m.id == "_" {
                    out.append(CommentNode(id: "cont-" + m.id + (m.parent_id ?? ""), kind: .continueThread(m.parent_id ?? ""), depth: depth))
                } else {
                    out.append(CommentNode(id: "more-" + m.id, kind: .more(m), depth: depth))
                    total += m.count ?? m.children.count
                }
            default: break
            }
        }
        return total
    }

    @MainActor
    func load(force: Bool = false) async {
        loading = true
        error = nil
        do {
            let r = try await Reddit.comments(postID: postID, permalink: post?.permalink, commentID: commentID, sort: sort, force: force)
            let collapseAuto = AppSettings.shared.collapseAutomod
            let built: ([CommentNode], Set<String>, Post?) = await Task.detached(priority: .userInitiated) {
                var out: [CommentNode] = []
                let things = r.value.count > 1 ? r.value[1].data.children : []
                _ = CommentsModel.flatten(things, depth: 0, into: &out)
                var col = Set<String>()
                if collapseAuto {
                    for n in out where n.depth == 0 {
                        if case .comment(let c, _) = n.kind, c.author == "AutoModerator", c.stickied == true { col.insert(n.id) }
                    }
                }
                var p: Post? = nil
                if let first = r.value.first?.data.children.first, case .post(let post) = first { p = post }
                return (out, col, p)
            }.value
            if let p = built.2 { setPost(p) }
            nodes = built.0
            collapsed = built.1
            staleNote = r.stale ? "\(r.error?.localizedDescription ?? "Offline") · cached" : nil
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    @MainActor
    func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    @MainActor
    func loadMore(_ node: CommentNode) async {
        guard case .more(let m) = node.kind, !loadingMore.contains(node.id) else { return }
        loadingMore.insert(node.id)
        defer { loadingMore.remove(node.id) }
        let batch = Array(m.children.prefix(100))
        let rest = Array(m.children.dropFirst(100))
        do {
            let things = try await Reddit.moreChildren(postID: postID, ids: batch, sort: sort)
            var depthOf: [String: Int] = [:]
            for n in nodes { depthOf[n.id] = n.depth }
            var new: [CommentNode] = []
            for t in things {
                switch t {
                case .comment(let c):
                    let parent = String((c.parent_id ?? "").dropFirst(3))
                    let d = depthOf[parent].map { $0 + 1 } ?? node.depth
                    depthOf[c.id] = d
                    new.append(CommentNode(id: c.id, kind: .comment(c, Markdown.parse(c.body ?? "")), depth: d))
                case .more(let mm):
                    let parent = String((mm.parent_id ?? "").dropFirst(3))
                    let d = depthOf[parent].map { $0 + 1 } ?? node.depth
                    if mm.children.isEmpty || mm.id == "_" {
                        new.append(CommentNode(id: "cont-" + mm.id + (mm.parent_id ?? ""), kind: .continueThread(mm.parent_id ?? ""), depth: d))
                    } else {
                        new.append(CommentNode(id: "more-" + mm.id, kind: .more(mm), depth: d))
                    }
                default: break
                }
            }
            if !rest.isEmpty {
                var remaining = m
                remaining.children = rest
                remaining.count = rest.count
                new.append(CommentNode(id: "more-" + m.id + "-\(rest.count)", kind: .more(remaining), depth: node.depth))
            }
            guard let idx = nodes.firstIndex(where: { $0.id == node.id }) else { return }
            let existing = Set(nodes.map(\.id))
            nodes.replaceSubrange(idx...idx, with: new.filter { !existing.contains($0.id) })
        } catch {
            Presenter.shared.show(error.localizedDescription)
        }
    }
}

struct PostDetailView: View {
    let ref: PostRef
    @State private var model: CommentsModel
    @State private var onScreen: Set<String> = []
    @Environment(Router.self) private var router
    private var settings: AppSettings { .shared }
    private var library: Library { .shared }

    init(ref: PostRef) {
        self.ref = ref
        _model = State(initialValue: CommentsModel(ref: ref))
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let post = model.post {
                    PostDetailHeader(post: post, blocks: model.selfBlocks)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.cardBackground)
                        .id("post-header")
                } else if model.loading {
                    ProgressView().frame(maxWidth: .infinity).padding(40).listRowSeparator(.hidden)
                }

                if ref.commentID != nil {
                    Button { router.open(PostRef(id: ref.id, preview: model.post)) } label: {
                        Label("Single comment thread · Show all comments", systemImage: "text.bubble")
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .listRowBackground(Color.accentColor.opacity(0.08))
                }

                if let note = model.staleNote { StaleBanner(text: note).plainRow() }

                Section {
                    if model.loading && !model.loaded {
                        ForEach(0..<6, id: \.self) { i in CommentSkeleton(depth: i % 3) }
                    } else if let e = model.error, model.nodes.isEmpty {
                        ErrorState(message: e) { Task { await model.load() } }.listRowSeparator(.hidden)
                    } else if model.loaded && model.nodes.isEmpty {
                        EmptyState(icon: "bubble.left.and.bubble.right", title: "No comments yet").listRowSeparator(.hidden)
                    }
                    ForEach(model.visible) { node in
                        nodeRow(node)
                            .id(node.id)
                            .onAppear { onScreen.insert(node.id) }
                            .onDisappear { onScreen.remove(node.id) }
                    }
                } header: {
                    if model.post != nil {
                        HStack {
                            Text("\((model.post?.num_comments ?? 0).compact) Comments")
                            Spacer()
                            sortMenu
                        }
                        .font(.footnote.weight(.semibold))
                        .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.cardBackground)
            .overlay(alignment: .bottomTrailing) {
                if settings.nextCommentButton && model.nodes.count > 3 {
                    Button { jumpToNext(proxy) } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 50, height: 50)
                            .background(Color.accentColor.gradient, in: Circle())
                            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    }
                    .padding(20)
                    .simultaneousGesture(LongPressGesture().onEnded { _ in jumpToPrevious(proxy) })
                }
            }
        }
        .handlesLinks(router)
        .navigationTitle(model.post.map { "r/\($0.subreddit)" } ?? "Post")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let post = model.post {
                    Menu { PostMenuItems(post: post, router: router) } label: { Label("More", systemImage: "ellipsis.circle") }
                }
            }
        }
        .refreshable { await model.load(force: true) }
        .task { if !model.loaded { await model.load() } }
        .onAppear { if let p = model.post { library.markRead(p) } }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(CommentSort.allCases) { s in
                Button {
                    model.sort = s
                    Task { await model.load() }
                } label: { if model.sort == s { Label(s.label, systemImage: "checkmark") } else { Text(s.label) } }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.sort.label)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder
    private func nodeRow(_ node: CommentNode) -> some View {
        switch node.kind {
        case .comment(let c, let blocks):
            CommentRow(comment: c, blocks: blocks, depth: node.depth, collapsed: model.collapsed.contains(node.id),
                       hidden: node.descendants, isOP: c.author == model.post?.author && c.author != "[deleted]",
                       highlighted: c.id == ref.commentID)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                .listRowSeparator(node.depth == 0 ? .visible : .hidden, edges: .top)
                .listRowSeparator(.hidden, edges: .bottom)
                .listRowBackground(c.id == ref.commentID ? Color.accentColor.opacity(0.1) : Color.cardBackground)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy(duration: 0.25)) { model.toggle(node.id) }; Haptics.tap(.soft) }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { collapseThread(of: node) } label: { Label("Collapse", systemImage: "arrow.up.to.line") }.tint(.accentColor)
                }
                .swipeActions(edge: .trailing) {
                    if let link = c.permalink, let u = URL(string: "https://www.reddit.com" + link) {
                        ShareLink(item: u) { Label("Share", systemImage: "square.and.arrow.up") }.tint(.blue)
                    }
                }
                .contextMenu {
                    Button { UIPasteboard.general.string = c.body; Presenter.shared.show("Copied") } label: { Label("Copy Text", systemImage: "doc.on.doc") }
                    if let link = c.permalink, let u = URL(string: "https://www.reddit.com" + link) {
                        ShareLink(item: u) { Label("Share", systemImage: "square.and.arrow.up") }
                        Button { UIPasteboard.general.url = u; Presenter.shared.show("Link copied") } label: { Label("Copy Link", systemImage: "link") }
                    }
                    Button { collapseThread(of: node) } label: { Label("Collapse Thread", systemImage: "arrow.up.to.line") }
                    Button { router.push(.user(c.author)) } label: { Label("u/\(c.author)", systemImage: "person.crop.circle") }
                    Button(role: .destructive) { library.filters.users.append(c.author); Presenter.shared.show("u/\(c.author) filtered") } label: {
                        Label("Filter User's Posts", systemImage: "nosign")
                    }
                }
        case .more(let m):
            // Reddit blocks the "load more" endpoint for apps, so open the parent's thread instead
            // (or the post on reddit.com for top-level overflow).
            Button {
                if Reddit.apiActive {
                    Task { await model.loadMore(node) }
                } else if let parent = m.parent_id, parent.hasPrefix("t1_") {
                    router.push(.post(PostRef(id: ref.id, commentID: String(parent.dropFirst(3)), preview: model.post)))
                } else if let p = model.post {
                    Presenter.shared.openExternal(p.webURL)
                }
            } label: {
                HStack(spacing: 8) {
                    if model.loadingMore.contains(node.id) { ProgressView().controlSize(.small) }
                    else { Image(systemName: Reddit.apiActive || (m.parent_id ?? "").hasPrefix("t1_") ? "arrow.turn.down.right" : "safari") }
                    Text(moreLabel(m))
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(node.depth) * 12 + 10)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.cardBackground)
        case .continueThread(let parent):
            Button { router.push(.post(PostRef(id: ref.id, commentID: String(parent.dropFirst(3)), preview: model.post))) } label: {
                Label("Continue this thread", systemImage: "arrow.right.circle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(node.depth) * 12 + 10)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.cardBackground)
        }
    }

    private func moreLabel(_ m: More) -> String {
        let n = m.count ?? m.children.count
        let noun = n == 1 ? "reply" : "replies"
        if Reddit.apiActive { return "Load \(n) more \(noun)" }
        if (m.parent_id ?? "").hasPrefix("t1_") { return "\(n) more \(noun) — open thread" }
        return "\(n) more comments on reddit.com"
    }

    private func collapseThread(of node: CommentNode) {
        // Collapse the top-level comment that contains this one.
        guard let idx = model.nodes.firstIndex(where: { $0.id == node.id }) else { return }
        var i = idx
        while i > 0 && model.nodes[i].depth > 0 { i -= 1 }
        withAnimation(.snappy) { model.collapsed.insert(model.nodes[i].id) }
        Haptics.tap()
    }

    private func jumpToNext(_ proxy: ScrollViewProxy) {
        let vis = model.visible
        let firstShown = vis.firstIndex { onScreen.contains($0.id) } ?? -1
        let start = max(0, firstShown + 1)
        if start < vis.count, let next = vis[start...].first(where: { $0.depth == 0 }) {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(next.id, anchor: .top) }
            Haptics.tap(.soft)
        }
    }

    private func jumpToPrevious(_ proxy: ScrollViewProxy) {
        let vis = model.visible
        guard let firstShown = vis.firstIndex(where: { onScreen.contains($0.id) }), firstShown > 0 else {
            withAnimation { proxy.scrollTo("post-header", anchor: .top) }; return
        }
        if let prev = vis[..<firstShown].last(where: { $0.depth == 0 }) {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(prev.id, anchor: .top) }
            Haptics.tap(.medium)
        }
    }
}

struct PostDetailHeader: View {
    let post: Post
    let blocks: [MDBlock]
    @Environment(Router.self) private var router
    private var library: Library { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { router.push(.feed(.subreddit(post.subreddit))) } label: {
                    HStack(spacing: 8) {
                        Avatar(name: post.subreddit, size: 28)
                        Text("r/\(post.subreddit)").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
                Button { router.push(.user(post.author)) } label: { Text("u/\(post.author)") }.buttonStyle(.plain)
                Text("· \(post.created.ago)")
                Spacer()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Text(post.title)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            PostBadges(post: post)

            if let x = post.crosspost_parent_list?.first {
                Button { router.open(PostRef(id: x.id, preview: x)) } label: {
                    Label("Crossposted from r/\(x.subreddit)", systemImage: "arrow.triangle.branch").font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            PostMediaView(post: post, detail: true)

            if !blocks.isEmpty {
                MarkdownView(blocks: blocks)
                    .font(.body)
                    .padding(post.crosspost_parent_list?.isEmpty == false ? 12 : 0)
                    .background(post.crosspost_parent_list?.isEmpty == false ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 18) {
                Label((post.score ?? 0).compact, systemImage: "arrow.up")
                if let r = post.upvote_ratio { Label("\(Int(r * 100))%", systemImage: "face.smiling") }
                Label((post.num_comments ?? 0).compact, systemImage: "bubble.left")
                Spacer()
            }
            .labelStyle(TightLabel())
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                action(library.isSaved(post.id) ? "Saved" : "Save", library.isSaved(post.id) ? "bookmark.fill" : "bookmark", on: library.isSaved(post.id)) {
                    let on = library.toggleSave(post); Haptics.success(); Presenter.shared.show(on ? "Saved" : "Unsaved")
                }
                ShareLink(item: post.webURL, subject: Text(post.title)) { actionLabel("Share", "square.and.arrow.up", on: false) }
                    .buttonStyle(.plain)
                if post.isExternalLink, let u = post.linkURL {
                    action("Open", "safari", on: false) { Presenter.shared.openExternal(u) }
                }
                action("Hide", "eye.slash", on: false) { library.hide(post.id); Presenter.shared.show("Hidden from feeds") }
            }
            .padding(.top, 2)
        }
    }

    private func action(_ title: String, _ icon: String, on: Bool, _ fn: @escaping () -> Void) -> some View {
        Button(action: fn) { actionLabel(title, icon, on: on) }.buttonStyle(.plain)
    }

    private func actionLabel(_ title: String, _ icon: String, on: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium))
            Text(title).font(.caption2.weight(.medium))
        }
        .foregroundStyle(on ? Color.accentColor : Color.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 3)
    }
}

struct CommentRow: View {
    let comment: Comment
    let blocks: [MDBlock]
    let depth: Int
    let collapsed: Bool
    let hidden: Int
    let isOP: Bool
    let highlighted: Bool
    @Environment(Router.self) private var router

    static let rail: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .yellow, .red]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if depth > 0 {
                RoundedRectangle(cornerRadius: 1)
                    .fill(CommentRow.rail[(depth - 1) % CommentRow.rail.count].opacity(0.75))
                    .frame(width: 2)
                    .padding(.vertical, 6)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(comment.author)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(authorColor)
                        .onTapGesture { router.push(.user(comment.author)) }
                    if isOP { Badge(text: "OP", color: .accentColor) }
                    if comment.distinguished == "moderator" { Badge(text: "MOD", color: .green) }
                    if comment.distinguished == "admin" { Badge(text: "ADMIN", color: .red) }
                    if comment.stickied == true { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.green) }
                    if AppSettings.shared.showFlair, let f = comment.author_flair_text, !f.isEmpty {
                        FlairView(text: f).layoutPriority(-1)
                    }
                    Spacer(minLength: 4)
                    if collapsed && hidden > 0 {
                        Text("+\(hidden)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.6), in: Capsule())
                    }
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                        Text(comment.score_hidden == true ? "•" : (comment.score ?? 0).compact)
                    }
                    .font(.caption.weight(.medium))
                    Text(comment.created.ago + (comment.edited?.isTrue == true ? "*" : "")).font(.caption)
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if !collapsed {
                    MarkdownView(blocks: blocks)
                        .font(.subheadline)
                }
            }
            .padding(.vertical, 9)
        }
        .padding(.leading, CGFloat(max(0, depth - 1)) * 12)
        .opacity(collapsed ? 0.7 : 1)
    }

    private var authorColor: Color {
        if comment.distinguished == "moderator" { return .green }
        if comment.distinguished == "admin" { return .red }
        if isOP { return .accentColor }
        return .primary
    }
}

struct CommentSkeleton: View {
    let depth: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4).frame(width: 120, height: 10)
            RoundedRectangle(cornerRadius: 4).frame(height: 10)
            RoundedRectangle(cornerRadius: 4).frame(width: 220, height: 10)
        }
        .foregroundStyle(Color.secondary.opacity(0.14))
        .overlay(ShimmerView())
        .padding(.vertical, 12)
        .padding(.leading, CGFloat(depth) * 14)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.cardBackground)
    }
}
