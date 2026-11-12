import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case home, communities, search, saved, settings
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .communities: return "square.grid.2x2.fill"
        case .search: return "magnifyingglass"
        case .saved: return "bookmark.fill"
        case .settings: return "gearshape.fill"
        }
    }
    /// Tabs that open posts get the feed | post split when there's room.
    var usesSplit: Bool { self != .settings }
}

/// Launch flags used by CI to photograph specific screens in the simulator.
enum LaunchArgs {
    static let args = ProcessInfo.processInfo.arguments
    static func value(_ key: String) -> String? {
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    static var initialTab: AppTab { value("-QXTab").flatMap(AppTab.init(rawValue:)) ?? .home }
    @MainActor static var openSample = args.contains("-QXOpenSample")
}

struct RootView: View {
    @State private var tab: AppTab = LaunchArgs.initialTab
    @Bindable private var presenter = Presenter.shared
    private var settings: AppSettings { .shared }

    var body: some View {
        TabView(selection: $tab) {
            ForEach(AppTab.allCases) { t in
                AdaptiveStack(split: t.usesSplit) { rootContent(t) }
                    .tabItem { Label(t.label, systemImage: t.icon) }
                    .tag(t)
            }
        }
        .overlay(alignment: .top) { PacingOverlay() }
        .overlay(alignment: .bottom) {
            if let t = presenter.toast {
                Toast(text: t)
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $presenter.safari) { u in SafariView(url: u.url).ignoresSafeArea() }
        .sheet(isPresented: $presenter.verify) {
            RedditVerifyView {
                let retry = presenter.afterVerify
                presenter.afterVerify = nil
                retry?()
            }
        }
        .fullScreenCover(item: $presenter.viewer) { v in MediaViewer(item: v) }
        .fullScreenCover(item: $presenter.video) { v in
            FullscreenVideoView(url: v.url)
        }
        .task {
            await RedditAccount.refresh()
            settings.apiSignedIn = await RedditAPIAuth.shared.hasTokens
        }
        .tint(settings.accent.color)
        .preferredColorScheme(settings.theme.scheme)
        .dynamicTypeSize(settings.textSize.dynamic)
    }

    @ViewBuilder
    private func rootContent(_ t: AppTab) -> some View {
        switch t {
        case .home: FeedView(source: .home)
        case .communities: CommunitiesView()
        case .search: SearchView()
        case .saved: SavedTab()
        case .settings: SettingsView()
        }
    }
}

private struct PacingOverlay: View {
    var body: some View {
        let s = NetworkStatus.shared
        if s.waiting > 0 {
            PacingPill()
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(duration: 0.35), value: s.waiting)
        }
    }
}

/// Feed and post side by side. One NavigationSplitView is used in every posture so that folding
/// or unfolding (iPhone Duo), rotating, or resizing never resets where you are: SwiftUI collapses
/// it into a single stack when the space is compact and expands it again when there's room.
struct AdaptiveStack<Root: View>: View {
    var split: Bool = true
    @ViewBuilder let root: () -> Root
    @State private var listRouter = Router()
    @State private var detailRouter = Router()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var wasWide: Bool?
    private var settings: AppSettings { .shared }

    var body: some View {
        Group {
            if settings.twoPane && split {
                NavigationSplitView(columnVisibility: $listRouter.columns, preferredCompactColumn: $listRouter.compactColumn) {
                    NavigationStack(path: $listRouter.path) {
                        root()
                            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                    }
                    .environment(listRouter)
                    .handlesLinks(listRouter)
                    .navigationSplitViewColumnWidth(min: 360, ideal: 460, max: 620)
                    .toolbar(removing: .sidebarToggle)
                } detail: {
                    NavigationStack(path: $detailRouter.path) {
                        Group {
                            if let ref = detailRouter.detailRoot {
                                PostDetailView(ref: ref).id(ref)
                            } else {
                                EmptyState(icon: "text.bubble", title: "Select a post", message: "Posts open here while your feed stays put.")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color.appBackground)
                            }
                        }
                        .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                    }
                    .environment(detailRouter)
                    .handlesLinks(detailRouter)
                }
                .navigationSplitViewStyle(.balanced)
                // Screens pushed from the sidebar can be hosted in the detail column, outside
                // either NavigationStack's environment. Provide a Router at the split-view level
                // too so @Environment(Router.self) can never come up empty (that's a hard crash).
                .environment(listRouter)
                .handlesLinks(listRouter)
            } else {
                NavigationStack(path: $listRouter.path) {
                    root()
                        .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                }
                .environment(listRouter)
                .handlesLinks(listRouter)
            }
        }
        .onAppear(perform: configure)
        .onChange(of: settings.twoPane) { _, _ in configure() }
        .onChange(of: sizeClass) { _, _ in configure() }
        .onChange(of: listRouter.compactColumn) { _, col in
            // Backing out of a post on the narrow display returns to the feed; clear the selection
            // so the wide layout doesn't show a stale post later.
            if col == .sidebar && sizeClass == .compact { detailRouter.detailRoot = nil }
        }
    }

    /// Two columns only when there's room (inner display unfolded, landscape, iPad). On the narrow
    /// outer display posts are pushed onto the stack like a normal iPhone app.
    private func configure() {
        let wide = settings.twoPane && split && sizeClass == .regular
        // Carry an open post across folding/unfolding so it always lands where posts belong.
        if let was = wasWide, was != wide {
            if wide, let ref = listRouter.compactPost, listRouter.path.count == listRouter.compactDepth, !listRouter.path.isEmpty {
                listRouter.path.removeLast()
                listRouter.compactPost = nil
                detailRouter.path = NavigationPath()
                detailRouter.detailRoot = ref
            } else if !wide, let ref = detailRouter.detailRoot {
                detailRouter.detailRoot = nil
                listRouter.compactColumn = .sidebar
                listRouter.path.append(Route.post(ref))
                listRouter.compactPost = ref
                listRouter.compactDepth = listRouter.path.count
            }
        }
        wasWide = wide
        listRouter.detail = detailRouter
        detailRouter.list = wide ? listRouter : nil
        listRouter.columns = .all
        listRouter.splitActive = wide
        detailRouter.splitActive = false
    }
}

struct RouteDestination: View {
    let route: Route
    var body: some View {
        switch route {
        case .feed(let s): FeedView(source: s)
        case .post(let ref): PostDetailView(ref: ref)
        case .user(let n): UserView(name: n)
        case .search(let sub): SearchView(restrictTo: sub)
        case .saved: SavedTab()
        case .history: SavedTab()
        case .discover: DiscoverView()
        }
    }
}
