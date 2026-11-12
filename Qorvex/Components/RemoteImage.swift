import SwiftUI
import UIKit

/// Memory + disk image cache. Images come from Reddit's CDN and don't count toward the JSON budget.
final class ImageLoader {
    static let shared = ImageLoader()
    private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession

    init() {
        memory.totalCostLimit = 120 * 1024 * 1024
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 30 * 1024 * 1024, diskCapacity: 500 * 1024 * 1024)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg)
    }

    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let img = cached(url) { return img }
        guard let (data, _) = try? await session.data(from: url), let raw = UIImage(data: data) else { return nil }
        let img = await raw.byPreparingForDisplay() ?? raw
        let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
        memory.setObject(img, forKey: url as NSURL, cost: cost)
        return img
    }

    func clear() {
        memory.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    var diskUsage: Int { session.configuration.urlCache?.currentDiskUsage ?? 0 }
}

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        _image = State(initialValue: url.flatMap { ImageLoader.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.12))
                    .overlay {
                        if failed { Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary) }
                        else { ShimmerView() }
                    }
            }
        }
        .task(id: url) {
            guard let url, image == nil else { return }
            let img = await ImageLoader.shared.load(url)
            withAnimation(.easeOut(duration: 0.2)) {
                image = img
                failed = img == nil
            }
        }
    }
}

struct ShimmerView: View {
    @State private var phase: CGFloat = -1
    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, Color.white.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.6)
                .offset(x: phase * geo.size.width * 1.4)
                .onAppear {
                    withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
                }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// Circular community / user avatar with a colourful lettered fallback.
struct Avatar: View {
    let name: String
    var url: URL? = nil
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let url {
                RemoteImage(url: url)
            } else {
                ZStack {
                    LinearGradient(colors: [Avatar.color(name), Avatar.color(name + "x")], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    static func color(_ s: String) -> Color {
        var h: UInt32 = 0
        for c in s.lowercased().unicodeScalars { h = h &* 31 &+ c.value }
        return Color(hue: Double(h % 360) / 360, saturation: 0.62, brightness: 0.86)
    }
}
