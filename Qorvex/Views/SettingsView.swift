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
    @State private var exporting = false
    @State private var importing = false
    @State private var confirmReset = false
    @State private var cacheInfo = "…"

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(settings.accent.color.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Qorvex").font(.headline)
                        Text("Free, private, no account. Paced to never hit Reddit's limit.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) { ForEach(AppTheme.allCases) { Text($0.label).tag($0) } }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Accent Color")
                    HStack(spacing: 0) {
                        ForEach(AccentChoice.allCases) { a in
                            Circle()
                                .fill(a.color.gradient)
                                .frame(width: 30, height: 30)
                                .overlay(Circle().stroke(Color.primary, lineWidth: settings.accent == a ? 2.5 : 0).padding(-4))
                                .frame(maxWidth: .infinity)
                                .onTapGesture { withAnimation(.snappy) { settings.accent = a }; Haptics.tap() }
                        }
                    }
                }
                .padding(.vertical, 4)
                Picker("Text Size", selection: $settings.textSize) { ForEach(TextSize.allCases) { Text($0.label).tag($0) } }
                Picker("Post Layout", selection: $settings.layout) { ForEach(PostLayout.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented)
                Toggle("Thumbnails in Compact", isOn: $settings.showThumbnails)
                Toggle("Show Flair", isOn: $settings.showFlair)
                Toggle(isOn: $settings.twoPane) {
                    VStack(alignment: .leading) {
                        Text("Two-Pane on Wide Screens")
                        Text("Feed and post side by side when unfolded, in landscape or on iPad").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Browsing") {
                Picker("Default Home Sort", selection: $settings.homeSort) { ForEach(SortOrder.allCases) { Text($0.label).tag($0) } }
                Picker("Default Comment Sort", selection: $settings.commentSort) { ForEach(CommentSort.allCases) { Text($0.label).tag($0) } }
                Toggle("Dim Read Posts", isOn: $settings.dimRead)
                Toggle("Hide Read Posts", isOn: $settings.hideRead)
                Toggle("Swipe Actions", isOn: $settings.swipeActions)
                Toggle("Next-Comment Button", isOn: $settings.nextCommentButton)
                Toggle("Collapse AutoModerator", isOn: $settings.collapseAutomod)
                Toggle("Haptics", isOn: $settings.haptics)
            }

            Section("Links") {
                Toggle("Open Links In-App", isOn: $settings.inAppBrowser)
                Toggle("Use Reader Mode", isOn: $settings.readerMode).disabled(!settings.inAppBrowser)
            }

            Section {
                Picker("Autoplay", selection: $settings.autoplay) { ForEach(AutoplayMode.allCases) { Text($0.label).tag($0) } }
                Toggle("Start Videos Muted", isOn: $settings.startMuted)
                Toggle("Data Saver", isOn: $settings.dataSaver)
            } header: { Text("Media") } footer: { Text("Data Saver loads smaller images and lower-bitrate video.") }

            Section("Content") {
                Picker("NSFW", selection: $settings.nsfw) { ForEach(NSFWMode.allCases) { Text($0.label).tag($0) } }
                Toggle("Blur Spoilers", isOn: $settings.blurSpoilers)
            }

            Section {
                NavigationLink { FilterEditor(title: "Keywords", items: Binding(get: { library.filters.keywords }, set: { library.filters.keywords = $0 }), placeholder: "word or phrase") } label: {
                    LabeledContent("Keywords", value: "\(library.filters.keywords.count)")
                }
                NavigationLink { FilterEditor(title: "Communities", items: Binding(get: { library.filters.subreddits }, set: { library.filters.subreddits = $0 }), placeholder: "subreddit") } label: {
                    LabeledContent("Communities", value: "\(library.filters.subreddits.count)")
                }
                NavigationLink { FilterEditor(title: "Users", items: Binding(get: { library.filters.users }, set: { library.filters.users = $0 }), placeholder: "username") } label: {
                    LabeledContent("Users", value: "\(library.filters.users.count)")
                }
                NavigationLink { FilterEditor(title: "Domains", items: Binding(get: { library.filters.domains }, set: { library.filters.domains = $0 }), placeholder: "example.com") } label: {
                    LabeledContent("Domains", value: "\(library.filters.domains.count)")
                }
            } header: { Text("Filters") } footer: { Text("Filtered posts never appear in any feed or search.") }

            Section {
                NetworkStatsView()
                Stepper(value: $settings.requestsPerMinute, in: 3...30) {
                    LabeledContent("Request Budget", value: "\(settings.requestsPerMinute) / min")
                }
                Picker("Cache Freshness", selection: $settings.cacheMode) { ForEach(CacheMode.allCases) { Text($0.label).tag($0) } }
                Picker("Source", selection: $settings.source) { ForEach(ImageSource.allCases) { Text($0.label).tag($0) } }
                Picker("Connection", selection: $settings.connection) { ForEach(ConnectionMode.allCases) { Text($0.label).tag($0) } }
                Button { Presenter.shared.verify = true } label: { Label("Open Reddit to Verify", systemImage: "safari") }
                NavigationLink { ConnectionLogView() } label: { Label("Connection Log", systemImage: "list.bullet.rectangle") }
                LabeledContent("Cache", value: cacheInfo)
                Button("Clear Cache", role: .destructive) {
                    Task {
                        await RedditClient.shared.clearCache()
                        ImageLoader.shared.clear()
                        await refreshCacheInfo()
                        Presenter.shared.show("Cache cleared")
                    }
                }
            } header: { Text("Network & Rate Limits") } footer: {
                Text("Connection: Automatic tries a direct request and switches to the built-in browser engine if Reddit filters it. If Reddit still blocks, use Open Reddit to Verify. Qorvex reads Reddit's public pages directly from your iPhone — no API key, no account, no server. It paces itself under Reddit's anonymous limit and serves repeat views from cache, so it never hammers Reddit. Keep the budget at 10 or below. If Reddit ever pushes back, Qorvex automatically slows down and shows cached content.")
            }

            Section {
                Button { exporting = true } label: { Label("Export Backup", systemImage: "square.and.arrow.up") }
                Button { importing = true } label: { Label("Import Backup", systemImage: "square.and.arrow.down") }
                Button { library.clearHistory(); Presenter.shared.show("History cleared") } label: { Label("Clear Reading History", systemImage: "clock.arrow.circlepath") }
                Button { library.hidden = []; Presenter.shared.show("Hidden posts restored") } label: { Label("Unhide All Posts", systemImage: "eye") }
                Button(role: .destructive) { confirmReset = true } label: { Label("Reset Settings", systemImage: "arrow.counterclockwise") }
            } header: { Text("Your Data") } footer: { Text("Communities, saved posts, history and filters live only on this device.") }

            Section {
                LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                Text("Qorvex is an independent reader and is not affiliated with Reddit.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task { await refreshCacheInfo() }
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
