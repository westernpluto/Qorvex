import SwiftUI

/// Renders a post's media: images, galleries, videos, YouTube, link cards — with NSFW/spoiler blur.
struct PostMediaView: View {
    let post: Post
    var detail = false
    @State private var revealed = false
    @State private var page = 0

    private var blurred: Bool {
        guard !revealed else { return false }
        let s = AppSettings.shared
        return (post.over_18 == true && s.nsfw == .blur) || (post.spoiler == true && s.blurSpoilers)
    }

    private func aspect(_ size: CGSize?, cap: CGFloat) -> CGFloat {
        guard let size, size.width > 0 else { return 16.0 / 10.0 }
        return max(size.width / size.height, 1 / cap)
    }

    var body: some View {
        switch post.mediaKind {
        case .image(let e):
            framed(aspect: aspect(e.size, cap: detail ? 1.8 : 1.25)) {
                RemoteImage(url: e.url)
            }
            .overlay(alignment: .bottomLeading) {
                if let s = e.size, s.height / s.width > (detail ? 1.8 : 1.25) { tag("Tall image", icon: "arrow.up.and.down") }
            }
            .onTapGesture { if !blurred { Presenter.shared.viewer = ViewerItem(entries: [e], index: 0, title: post.title) } }

        case .gallery(let entries):
            framed(aspect: aspect(entries.first?.size, cap: 1.25)) {
                TabView(selection: $page) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { i, e in
                        RemoteImage(url: e.url)
                            .overlay { if e.mp4 != nil { Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.9)) } }
                            .tag(i)
                            .contentShape(Rectangle())
                            .onTapGesture { if !blurred { Presenter.shared.viewer = ViewerItem(entries: entries, index: i, title: post.title) } }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: entries.count > 1 ? .automatic : .never))
            }
            .overlay(alignment: .topTrailing) {
                if entries.count > 1 { tag("\(page + 1)/\(entries.count)", icon: "square.stack").padding(.top, 0) }
            }

        case .video(let v):
            framed(aspect: aspect(v.size, cap: detail ? 1.6 : 1.25)) {
                InlineVideo(info: v, detail: detail)
            }

        case .youtube(_, let url, let thumb):
            framed(aspect: 16.0 / 9.0) {
                ZStack {
                    RemoteImage(url: thumb)
                    Image(systemName: "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 62, height: 62)
                        .background(Color.red.gradient, in: Circle())
                        .shadow(radius: 8)
                }
            }
            .onTapGesture { if !blurred { UIApplication.shared.open(url) } }

        case .link(let url, let domain, let thumb):
            LinkCard(url: url, domain: domain, thumb: thumb)

        case .text, .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func framed<Content: View>(aspect: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay { content() }
            .overlay {
                if blurred {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        VStack(spacing: 6) {
                            Image(systemName: post.over_18 == true ? "eye.slash.fill" : "exclamationmark.bubble.fill").font(.title2)
                            Text(post.over_18 == true ? "NSFW" : "Spoiler").font(.headline)
                            Text("Tap to reveal").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.25)) { revealed = true } }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: detail ? 14 : 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func tag(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white)
            .padding(8)
    }
}

struct LinkCard: View {
    let url: URL
    let domain: String
    let thumb: URL?

    var body: some View {
        Button {
            Presenter.shared.openExternal(url)
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let thumb { RemoteImage(url: thumb) } else {
                        Image(systemName: "safari").font(.title2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.secondary.opacity(0.12))
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(domain).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(url.absoluteString.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "www.", with: ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
