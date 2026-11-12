import SwiftUI

struct HintCard: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct StaleBanner: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "clock.arrow.circlepath")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var message: String = ""
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.accentColor.gradient)
                .frame(width: 76, height: 76)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            Text(title).font(.headline)
            if !message.isEmpty {
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48).padding(.horizontal, 24)
    }
}

struct ErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        let net = NetworkStatus.shared
        VStack(spacing: 14) {
            if net.loginRequired {
                EmptyState(icon: "person.crop.circle.badge.exclamationmark", title: "Sign in to keep reading",
                           message: "Reddit now only serves feeds to signed-in accounts. Sign in on Reddit's own page — Qorvex never sees your password. Saved and cached posts still work.")
                Button {
                    Presenter.shared.afterVerify = retry
                    Presenter.shared.verify = true
                } label: { Label("Sign in to Reddit", systemImage: "person.crop.circle") }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                Button("Try Again", action: retry).buttonStyle(.bordered).buttonBorderShape(.capsule)
            } else if net.blocked {
                EmptyState(icon: "hand.raised", title: message,
                           message: "Reddit is filtering this connection. Signing in to Reddit usually fixes it. Cached and saved posts still work.")
                Button {
                    Presenter.shared.afterVerify = retry
                    Presenter.shared.verify = true
                } label: { Label("Sign in to Reddit", systemImage: "person.crop.circle") }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                Button("Try Again", action: retry).buttonStyle(.bordered).buttonBorderShape(.capsule)
            } else {
                EmptyState(icon: "exclamationmark.triangle", title: message, message: "Your cached and saved posts still work offline.")
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(.bottom, 24)
    }
}

struct SkeletonFeed: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Circle().frame(width: 20, height: 20); RoundedRectangle(cornerRadius: 4).frame(width: 140, height: 10) }
                    RoundedRectangle(cornerRadius: 5).frame(height: 14)
                    RoundedRectangle(cornerRadius: 5).frame(width: 200, height: 14)
                    RoundedRectangle(cornerRadius: 12).frame(height: 190)
                }
                .foregroundStyle(Color.secondary.opacity(0.14))
                .overlay(ShimmerView())
                .padding(14)
                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }
}

/// Small floating pill shown while the request governor is pacing.
struct PacingPill: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("Pacing requests to stay under Reddit's limit").font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

struct SubredditRow: View {
    let sub: Subreddit
    private var library: Library { .shared }
    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: sub.display_name, url: sub.iconURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("r/\(sub.display_name)").font(.subheadline.weight(.semibold))
                    if sub.over18 == true { Badge(text: "NSFW", color: .red) }
                }
                Text([sub.subscribers.map { "\($0.compact) members" }, sub.public_description].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            JoinButton(name: sub.display_name)
        }
        .padding(.vertical, 4)
    }
}

struct JoinButton: View {
    let name: String
    private var library: Library { .shared }
    var body: some View {
        let on = library.isSubscribed(name)
        Button {
            let join = !on
            library.toggleSubscription(name)
            Haptics.success()
            guard NetworkStatus.shared.signedIn else { return }
            Task {
                do { try await RedditClient.shared.subscribe(name, join: join) }
                catch {
                    library.toggleSubscription(name) // revert
                    Presenter.shared.show("Couldn't \(join ? "join" : "leave") r/\(name)")
                }
            }
        } label: {
            Text(on ? "Joined" : "Join")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .foregroundStyle(on ? Color.primary : Color.white)
                .background(on ? AnyShapeStyle(Color.secondary.opacity(0.18)) : AnyShapeStyle(Color.accentColor.gradient), in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: on)
    }
}

struct UserRow: View {
    let user: RedditUser
    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: user.name, url: user.iconURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("u/\(user.name)").font(.subheadline.weight(.semibold))
                Text("\(user.karma.compact) karma").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Header with banner, icon, stats and join button.
struct SubredditHeader: View {
    let name: String
    /// Community details that arrived with the feed itself (no extra request).
    var detail: Subreddit? = nil
    @State private var fetched: Subreddit?
    @State private var showAbout = false

    private var info: Subreddit? { detail ?? fetched }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The banner fills a fixed frame; it must never decide the layout's width.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 104)
                .background(LinearGradient(colors: [Avatar.color(name), Avatar.color(name + "x").opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { if let b = info?.bannerURL { RemoteImage(url: b) } }
                .clipped()

            HStack(alignment: .bottom, spacing: 12) {
                Avatar(name: name, url: info?.iconURL ?? Library.shared.icon(for: name), size: 64)
                    .overlay(Circle().stroke(Color.appBackground, lineWidth: 4))
                    .offset(y: -20)
                    .padding(.bottom, -20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("r/\(info?.display_name ?? name)")
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    HStack(spacing: 4) {
                        if let s = info?.subscribers { Text("\(s.compact) members") }
                        if let o = info?.online, o > 0 {
                            Text("·")
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text("\(o.compact) online")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                JoinButton(name: name)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if let d = info?.public_description, !d.isEmpty {
                Text(Markdown.plain(d))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 10)
                    .contentShape(Rectangle())
                    .onTapGesture { showAbout = true }
            }
            Button {
                if Reddit.apiActive { showAbout = true }
                else { Presenter.shared.openExternal(URL(string: "https://www.reddit.com/r/\(name)/about/")!) }
            } label: {
                Label(Reddit.apiActive ? "About this community" : "About this community on reddit.com",
                      systemImage: Reddit.apiActive ? "info.circle" : "safari").font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: detail?.display_name) {
            // Only ask Reddit when the feed didn't already include the community's details.
            guard detail == nil, fetched == nil, Reddit.apiActive else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard detail == nil else { return }
            fetched = try? await Reddit.about(name)
        }
        .sheet(isPresented: $showAbout) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let i = info {
                            HStack(spacing: 14) {
                                Avatar(name: name, url: i.iconURL, size: 56)
                                VStack(alignment: .leading) {
                                    Text("r/\(i.display_name)").font(.title3.bold())
                                    if let s = i.subscribers { Text("\(s.compact) members").foregroundStyle(.secondary) }
                                }
                            }
                            MarkdownView(blocks: Markdown.parse(i.description?.isEmpty == false ? i.description! : (i.public_description ?? "No description.")))
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    }
                    .padding(20)
                }
                .navigationTitle("About")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAbout = false } } }
            }
            .presentationDragIndicator(.visible)
        }
    }
}

/// Shown at the top of feeds while signed out.
struct SignInBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in to Reddit").font(.headline)
                    Text("These are example posts. Sign in to load your feed, communities and comments.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Button { Presenter.shared.verify = true } label: {
                Text("Sign In").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
        .padding(16)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
