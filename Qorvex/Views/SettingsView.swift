import SwiftUI
import UniformTypeIdentifiers

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    private var library: Library { .shared }

    var body: some View {
        Form {
            Section { AccountCard() }

            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) { ForEach(AppTheme.allCases) { Text($0.label).tag($0) } }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Accent Color")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 8), spacing: 10) {
                        ForEach(AccentChoice.allCases) { a in
                            Circle()
                                .fill(a.color.gradient)
                                .frame(width: 26, height: 26)
                                .padding(5)
                                .overlay(Circle().stroke(Color.primary, lineWidth: settings.accent == a ? 2 : 0))
                                .contentShape(Circle())
                                .onTapGesture { withAnimation(.snappy) { settings.accent = a }; Haptics.tap() }
                                .accessibilityLabel(a.rawValue.capitalized)
                        }
                    }
                }
                .padding(.vertical, 6)
                Picker("Text Size", selection: $settings.textSize) { ForEach(TextSize.allCases) { Text($0.label).tag($0) } }
                Picker("Layout", selection: $settings.layout) { ForEach(PostLayout.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented)
                Toggle("Two-Pane Layout", isOn: $settings.twoPane)
            }

            Section("Reading") {
                Picker("Comment Sort", selection: $settings.commentSort) { ForEach(CommentSort.allCases) { Text($0.label).tag($0) } }
                Toggle("Dim Read Posts", isOn: $settings.dimRead)
                Toggle("Swipe Actions", isOn: $settings.swipeActions)
                Toggle("Next-Comment Button", isOn: $settings.nextCommentButton)
                Toggle("Open Links In-App", isOn: $settings.inAppBrowser)
            }

            Section("Media") {
                Picker("Autoplay", selection: $settings.autoplay) { ForEach(AutoplayMode.allCases) { Text($0.label).tag($0) } }
                Toggle("Start Videos Muted", isOn: $settings.startMuted)
                Picker("NSFW", selection: $settings.nsfw) { ForEach(NSFWMode.allCases) { Text($0.label).tag($0) } }
                Toggle("Blur Spoilers", isOn: $settings.blurSpoilers)
            }

            Section {
                NavigationLink { FiltersSettingsView() } label: {
                    LabeledContent("Filters", value: "\(library.filters.keywords.count + library.filters.subreddits.count + library.filters.users.count + library.filters.domains.count)")
                }
                NavigationLink("Your Data") { DataSettingsView() }
                NavigationLink("Advanced") { AdvancedSettingsView() }
            }

            Section {
                LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
            } footer: {
                Text("Qorvex is an independent app and is not affiliated with Reddit.")
            }
        }
        .navigationTitle("Settings")
        .task { await RedditAccount.refresh() }
    }
}

/// Signed-in account at the top of Settings.
struct AccountCard: View {
    var body: some View {
        let net = NetworkStatus.shared
        if net.signedIn {
            HStack(spacing: 14) {
                Avatar(name: net.username ?? "R", url: net.username.flatMap { AvatarStore.shared.url(for: $0) }, size: 44)
                Text(net.username.map { "u/\($0)" } ?? "Signed in")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 4)
            Button("Sign Out", role: .destructive) {
                Task { await RedditAccount.signOut(); Presenter.shared.show("Signed out") }
            }
        } else {
            Button { Presenter.shared.verify = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 40)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sign in to Reddit").font(.headline).foregroundStyle(.primary)
                        Text("Required to load your feed").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct FiltersSettingsView: View {
    private var library: Library { .shared }
    var body: some View {
        Form {
            Section {
                NavigationLink { FilterEditor(title: "Keywords", items: Binding(get: { library.filters.keywords }, set: { library.filters.keywords = $0 }), placeholder: "word or phrase") } label: {
                    LabeledContent("Keywords", value: "\(library.filters.keywords.count)")
                }
                NavigationLink { FilterEditor(title: "Communities", items: Binding(get: { library.filters.subreddits }, set: { library.filters.subreddits = $0 }), placeholder: "community") } label: {
                    LabeledContent("Communities", value: "\(library.filters.subreddits.count)")
                }
                NavigationLink { FilterEditor(title: "Users", items: Binding(get: { library.filters.users }, set: { library.filters.users = $0 }), placeholder: "username") } label: {
                    LabeledContent("Users", value: "\(library.filters.users.count)")
                }
                NavigationLink { FilterEditor(title: "Domains", items: Binding(get: { library.filters.domains }, set: { library.filters.domains = $0 }), placeholder: "example.com") } label: {
                    LabeledContent("Domains", value: "\(library.filters.domains.count)")
                }
            } footer: { Text("Filtered posts never appear in any feed or search.") }
            Section {
                Toggle("Hide Read Posts", isOn: Binding(get: { AppSettings.shared.hideRead }, set: { AppSettings.shared.hideRead = $0 }))
                Toggle("Collapse AutoModerator", isOn: Binding(get: { AppSettings.shared.collapseAutomod }, set: { AppSettings.shared.collapseAutomod = $0 }))
            }
        }
        .navigationTitle("Filters")
    }
}

struct DataSettingsView: View {
    private var library: Library { .shared }
    @Bindable private var settings = AppSettings.shared
    @State private var exporting = false
    @State private var importing = false
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Button { exporting = true } label: { Label("Export Backup", systemImage: "square.and.arrow.up") }
                Button { importing = true } label: { Label("Import Backup", systemImage: "square.and.arrow.down") }
            } footer: { Text("Saved posts, history and filters are stored on this device.") }
            Section {
                Button { library.clearHistory(); Presenter.shared.show("History cleared") } label: { Label("Clear Reading History", systemImage: "clock.arrow.circlepath") }
                Button { library.hidden = []; Presenter.shared.show("Hidden posts restored") } label: { Label("Unhide All Posts", systemImage: "eye") }
                Button(role: .destructive) { confirmReset = true } label: { Label("Reset Settings", systemImage: "arrow.counterclockwise") }
            }
        }
        .navigationTitle("Your Data")
        .fileExporter(isPresented: $exporting, document: BackupDocument(data: library.exportData()), contentType: .json, defaultFilename: "qorvex-backup") { result in
            if case .success = result { Presenter.shared.show("Backup exported") }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            do {
                try library.importData(Data(contentsOf: url))
                Presenter.shared.show("Backup restored")
            } catch { Presenter.shared.show("That file isn't a Qorvex backup") }
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Settings", role: .destructive) { settings.reset() }
        }
    }
}

struct AdvancedSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var cacheInfo = "…"

    var body: some View {
        Form {
            Section {
                NetworkStatsView()
                if settings.sessionCooldownUntil > Date() {
                    Label("Reddit paused requests — retrying \(settings.sessionCooldownUntil.formatted(date: .omitted, time: .shortened))", systemImage: "pause.circle")
                        .font(.footnote).foregroundStyle(.orange)
                    Button("Retry Now") { settings.sessionCooldownUntil = .distantPast }
                }
                Stepper(value: $settings.requestsPerMinute, in: 3...30) {
                    LabeledContent("Request Budget", value: "\(settings.requestsPerMinute) / min")
                }
                Picker("Cache Freshness", selection: $settings.cacheMode) { ForEach(CacheMode.allCases) { Text($0.label).tag($0) } }
                Toggle("Data Saver", isOn: $settings.dataSaver)
            } header: { Text("Network") } footer: {
                Text("Qorvex paces its requests and reuses cached pages so it stays well under Reddit's limits.")
            }

            Section {
                LabeledContent("Cache", value: cacheInfo)
                Button("Clear Cache", role: .destructive) {
                    Task {
                        await RedditClient.shared.clearCache()
                        ImageLoader.shared.clear()
                        await refreshCacheInfo()
                        Presenter.shared.show("Cache cleared")
                    }
                }
                NavigationLink { ConnectionLogView() } label: { Label("Connection Log", systemImage: "list.bullet.rectangle") }
                NavigationLink { CrashReportsView() } label: { Label("Crash Reports", systemImage: "exclamationmark.octagon") }
            } header: { Text("Diagnostics") }

            Section {
                TextField("Client ID", text: $settings.apiClientID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                TextField("Redirect URI", text: $settings.apiRedirectURI)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                TextField("User Agent", text: $settings.apiUserAgent, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.footnote.monospaced())
                if settings.apiSignedIn {
                    Label("Connected with your API key", systemImage: "key.fill").foregroundStyle(.green)
                    if settings.connection != .api { Button("Use API Key") { settings.connection = .api } }
                    Button("Disconnect API Key", role: .destructive) {
                        Task { await RedditAPISignIn.shared.signOut(); Presenter.shared.show("API key disconnected") }
                    }
                } else {
                    Button {
                        Task {
                            do {
                                try await RedditAPISignIn.shared.signIn()
                                settings.connection = .api
                                Haptics.success()
                                Presenter.shared.show("Connected with your API key")
                            } catch {
                                Presenter.shared.show(error.localizedDescription)
                            }
                        }
                    } label: { Label("Connect API Key", systemImage: "key") }
                    .disabled(settings.apiClientID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("Your Own API Key (Optional)") } footer: {
                Text("If you have your own Reddit app (reddit.com/prefs/apps, type “installed app”), connect it here. Its redirect URI must match exactly. Not needed for normal use.")
            }

            Section {
                Picker("Connection", selection: $settings.connection) { ForEach(ConnectionMode.allCases) { Text($0.label).tag($0) } }
            } footer: { Text("Leave on Automatic unless you're troubleshooting.") }
        }
        .navigationTitle("Advanced")
        .task { await refreshCacheInfo() }
    }

    private func refreshCacheInfo() async {
        let s = await RedditClient.shared.cacheStats()
        let total = s.bytes + ImageLoader.shared.diskUsage
        cacheInfo = "\(s.files) pages · " + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}

struct NetworkStatsView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let s = NetworkStatus.shared
            let used = s.usedThisMinute
            let budget = AppSettings.shared.requestsPerMinute
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("This minute").font(.subheadline)
                    Spacer()
                    Text("\(used) of \(budget)").font(.subheadline.monospacedDigit().weight(.semibold))
                }
                ProgressView(value: Double(min(used, budget)), total: Double(max(budget, 1)))
                    .tint(used >= budget ? .orange : .accentColor)
                HStack {
                    stat("\(s.totalRequests)", "network")
                    Divider().frame(height: 28)
                    stat("\(s.cacheHits)", "from cache")
                    Divider().frame(height: 28)
                    stat(s.waiting > 0 ? "\(s.waiting)" : "0", "queued")
                }
                if s.usingBrowserEngine {
                    Label("Using browser engine", systemImage: "safari").font(.caption).foregroundStyle(.secondary)
                }
                if let e = s.lastError {
                    Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.headline.monospacedDigit())
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct FilterEditor: View {
    let title: String
    @Binding var items: [String]
    let placeholder: String
    @State private var new = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add \(placeholder)", text: $new)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Add", action: add).disabled(new.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section {
                if items.isEmpty { Text("Nothing filtered").foregroundStyle(.secondary) }
                ForEach(items, id: \.self) { Text($0) }
                    .onDelete { items.remove(atOffsets: $0) }
            }
        }
        .navigationTitle(title)
        .toolbar { EditButton() }
    }

    private func add() {
        let v = new.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "r/", with: "").replacingOccurrences(of: "u/", with: "")
        guard !v.isEmpty, !items.contains(v) else { return }
        items.append(v)
        new = ""
    }
}

struct ConnectionLogView: View {
    var body: some View {
        let status = NetworkStatus.shared
        List {
            if status.log.isEmpty {
                Text("No requests yet. Open a feed, then come back.").foregroundStyle(.secondary)
            }
            ForEach(status.log) { e in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(e.status)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle((200..<300).contains(e.status) ? Color.green : Color.orange)
                        Text(e.via).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                        Spacer()
                        Text(e.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(e.url).font(.caption.monospaced()).lineLimit(3)
                    if !e.contentType.isEmpty { Text(e.contentType).font(.caption2).foregroundStyle(.secondary) }
                    if let l = e.location { Text("→ \(l)").font(.caption.monospaced()).foregroundStyle(.orange).lineLimit(3) }
                    if !e.snippet.isEmpty { Text(e.snippet).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(4) }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Connection Log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = status.logText
                    Presenter.shared.show("Log copied")
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                .disabled(status.log.isEmpty)
            }
        }
    }
}

struct CrashReportsView: View {
    @State private var reports = CrashReporter.loadReports()

    var body: some View {
        List {
            if reports.isEmpty {
                Text("No crash reports yet. iOS delivers them the next time the app opens after a crash.").foregroundStyle(.secondary)
            }
            ForEach(reports) { r in
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.date.formatted(date: .abbreviated, time: .standard)).font(.subheadline.weight(.semibold))
                    Text(r.summary).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Button {
                        UIPasteboard.general.string = r.summary + "\n\n" + r.details
                        Presenter.shared.show("Crash report copied")
                    } label: { Label("Copy Full Report", systemImage: "doc.on.doc") }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Crash Reports")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { CrashReporter.clear(); reports = [] } label: { Label("Clear", systemImage: "trash") }
                    .disabled(reports.isEmpty)
            }
        }
        .refreshable { reports = CrashReporter.loadReports() }
    }
}
