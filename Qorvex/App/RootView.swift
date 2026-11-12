import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case home, popular, search, library, settings
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .popular: return "flame.fill"
        case .search: return "magnifyingglass"
        case .library: return "books.vertical.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct RootView: View {
    @State private var tab: AppTab = .home
    @Bindable private var presenter = Presenter.shared
    private var settings: AppSettings { .shared }

    var body: some View {
        TabView(selection: $tab) {
            ForEach(AppTab.allCases) { t in
                AdaptiveStack { rootContent(t) }
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
        .fullScreenCover(item: $presenter.viewer) { v in MediaViewer(item: v) }
        .fullScreenCover(item: $presenter.video) { v in
            FullscreenPlayer(url: v.url)
                .ignoresSafeArea()
                .overlay(alignment: .topLeading) {
                    CircleButton(system: "xmark") { presenter.video = nil }
                        .foregroundStyle(.white)
                        .padding(.leading, 16).padding(.top, 8)
                }
        }
        .tint(settings.accent.color)
        .preferredColorScheme(settings.theme.scheme)
        .dynamicTypeSize(settings.textSize.dynamic)
    }

    @ViewBuilder
    private func rootContent(_ t: AppTab) -> some View {
        switch t {
        case .home: FeedView(source: .home)
        case .popular: FeedView(source: .popular)
        case .search: SearchView()
        case .library: LibraryView()
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
    @ViewBuilder let root: () -> Root
    @State private var listRouter = Router()
    @State private var detailRouter = Router()
    @State private var columns: NavigationSplitViewVisibility = .all
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var settings: AppSettings { .shared }

    var body: some View {
        Group {
            if settings.twoPane {
                NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $listRouter.compactColumn) {
                    NavigationStack(path: $listRouter.path) {
                        root()
                            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                    }
                    .environment(listRouter)
                    .handlesLinks(listRouter)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 560)
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
        .onChange(of: listRouter.compactColumn) { _, col in
            // Backing out of a post on the narrow display returns to the feed; clear the selection
            // so the wide layout doesn't show a stale post later.
            if col == .sidebar && sizeClass == .compact { detailRouter.detailRoot = nil }
        }
    }

    private func configure() {
        listRouter.detail = detailRouter
        listRouter.splitActive = settings.twoPane
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
        case .saved: SavedView()
        case .history: HistoryView()
        case .discover: DiscoverView()
        }
    }
}
