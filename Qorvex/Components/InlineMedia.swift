import SwiftUI
import AVFoundation
import WebKit
import ImageIO

/// Animated GIF that plays in place.
struct AnimatedGIFView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.clipsToBounds = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        context.coordinator.load(url, into: v)
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {
        if context.coordinator.loaded != url { context.coordinator.load(url, into: v) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loaded: URL?
        private var task: Task<Void, Never>?

        func load(_ url: URL, into view: UIImageView) {
            loaded = url
            task?.cancel()
            task = Task { [weak view] in
                guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                let image = await Task.detached(priority: .userInitiated) { Self.decode(data) }.value
                await MainActor.run { view?.image = image }
            }
        }

        static func decode(_ data: Data) -> UIImage? {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
            let count = CGImageSourceGetCount(src)
            guard count > 1 else { return UIImage(data: data) }
            var frames: [UIImage] = []
            var total: Double = 0
            for i in 0..<min(count, 300) {
                guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
                frames.append(UIImage(cgImage: cg))
                let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
                let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                total += delay < 0.02 ? 0.1 : delay
            }
            return UIImage.animatedImage(with: frames, duration: total)
        }
    }
}

/// YouTube video playing inline (privacy-enhanced embed).
struct YouTubeEmbed: UIViewRepresentable {
    let id: String
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsPictureInPictureMediaPlayback = true
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.isOpaque = false
        v.backgroundColor = .black
        v.scrollView.isScrollEnabled = false
        // YouTube refuses embeds without a referring origin ("video player configuration
        // error"), so host the player in a small page with a real origin.
        let origin = "https://qorvex.app"
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="https://www.youtube.com/embed/\(id)?playsinline=1&autoplay=1&rel=0&origin=\(origin)&widget_referrer=\(origin)"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen
          referrerpolicy="strict-origin-when-cross-origin"></iframe>
        </body></html>
        """
        v.loadHTMLString(html, baseURL: URL(string: origin))
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

/// An image, GIF or short video embedded in a comment or text post, shown in place.
/// Sized to the media's real proportions (measured after loading when Reddit doesn't say),
/// and the rounded background hugs the media instead of the maximum box.
struct InlineMediaView: View {
    let entry: GalleryEntry
    @State private var measured: CGSize?

    private var size: CGSize? { entry.size ?? measured }

    private var aspect: CGFloat {
        guard let s = size, s.width > 0, s.height > 0 else { return 1 }
        return max(s.width / s.height, 0.5)
    }

    var body: some View {
        Group {
            if size == nil {
                // Small neutral placeholder until the real proportions are known.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 160, height: 120)
                    .overlay(ShimmerView())
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                media
                    .aspectRatio(aspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: 340, maxHeight: 320, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
        .task(id: entry.id) {
            guard entry.size == nil, measured == nil else { return }
            measured = await Self.measure(entry)
        }
    }

    @ViewBuilder private var media: some View {
        if let mp4 = entry.mp4 {
            InlineVideo(info: VideoInfo(hls: nil, mp4: mp4, poster: entry.mp4 == entry.url ? nil : entry.url, size: size, isGif: true, duration: nil))
        } else if entry.url.pathExtension.lowercased() == "gif" {
            AnimatedGIFView(url: entry.url)
        } else {
            RemoteImage(url: entry.url, contentMode: .fit)
                .onTapGesture { Presenter.shared.viewer = ViewerItem(entries: [entry], index: 0, title: "") }
        }
    }

    /// Natural size of the media: video track size, or the image's pixel size.
    static func measure(_ e: GalleryEntry) async -> CGSize? {
        if let mp4 = e.mp4 {
            let asset = AVURLAsset(url: mp4)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let r = CGRect(origin: .zero, size: natural).applying(transform)
                let s = CGSize(width: abs(r.width), height: abs(r.height))
                if s.width > 0 && s.height > 0 { return s }
            }
        }
        if let img = await ImageLoader.shared.load(e.url) {
            return img.size
        }
        return CGSize(width: 4, height: 3)
    }
}
