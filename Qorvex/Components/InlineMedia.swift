import SwiftUI
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
        if let u = URL(string: "https://www.youtube-nocookie.com/embed/\(id)?playsinline=1&autoplay=1&rel=0&modestbranding=1") {
            v.load(URLRequest(url: u))
        }
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

/// An image, GIF or short video embedded in a comment or text post, shown in place.
struct InlineMediaView: View {
    let entry: GalleryEntry

    private var aspect: CGFloat {
        guard let s = entry.size, s.width > 0, s.height > 0 else { return 4.0 / 3.0 }
        return max(s.width / s.height, 0.6)
    }

    var body: some View {
        Group {
            if let mp4 = entry.mp4 {
                InlineVideo(info: VideoInfo(hls: nil, mp4: mp4, poster: entry.mp4 == entry.url ? nil : entry.url, size: entry.size, isGif: true, duration: nil))
            } else if entry.url.pathExtension.lowercased() == "gif" {
                AnimatedGIFView(url: entry.url)
            } else {
                RemoteImage(url: entry.url, contentMode: .fit)
                    .onTapGesture { Presenter.shared.viewer = ViewerItem(entries: [entry], index: 0, title: "") }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: 340, maxHeight: 300, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 2)
    }
}
