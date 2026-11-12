import Foundation
import CoreGraphics

struct GalleryEntry: Identifiable, Hashable {
    let id: String
    let url: URL
    let full: URL
    let size: CGSize?
    let caption: String?
    let mp4: URL?

    static func == (a: GalleryEntry, b: GalleryEntry) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct VideoInfo: Hashable {
    let hls: URL?
    let mp4: URL?
    let poster: URL?
    let size: CGSize?
    let isGif: Bool
    let duration: Int?
    var playURL: URL? { hls ?? mp4 }
}

enum PostMedia {
    case image(GalleryEntry)
    case gallery([GalleryEntry])
    case video(VideoInfo)
    case youtube(id: String, url: URL, thumb: URL?)
    case link(url: URL, domain: String, thumb: URL?)
    case text
    case none
}

extension Post {
    private func pick(_ list: [ImageRes], target: Int) -> ImageRes? {
        let want = AppSettings.shared.dataSaver ? min(target, 640) : target
        return list.first(where: { $0.width >= want }) ?? list.last
    }

    func previewImage(target: Int = 1080) -> GalleryEntry? {
        guard let img = preview?.images?.first, let src = img.source else { return nil }
        let r = pick((img.resolutions ?? []) + [src], target: target) ?? src
        guard let u = URL(string: r.url), let full = URL(string: src.url) else { return nil }
        return GalleryEntry(id: id, url: u, full: full, size: CGSize(w: src.width, h: src.height), caption: nil, mp4: nil)
    }

    var thumbnailURL: URL? {
        previewImage(target: 320)?.url ?? URL.nonEmpty(thumbnail)
    }

    var mediaKind: PostMedia {
        let p = crosspost_parent_list?.first ?? self
        return p.ownMedia
    }

    private var ownMedia: PostMedia {
        let urlString = url_overridden_by_dest ?? url ?? ""

        if is_gallery == true, let meta = media_metadata, let items = gallery_data?.items {
            let entries: [GalleryEntry] = items.compactMap { it in
                guard let m = meta[it.media_id], m.status == "valid", let s = m.s else { return nil }
                if m.e == "AnimatedImage" {
                    guard let poster = URL(string: s.gif ?? s.u ?? "") ?? URL(string: s.mp4 ?? "") else { return nil }
                    return GalleryEntry(id: it.media_id, url: poster, full: poster, size: CGSize(w: s.x, h: s.y), caption: it.caption, mp4: s.mp4.flatMap(URL.init(string:)))
                }
                let all = (m.p ?? []) + [s]
                let want = AppSettings.shared.dataSaver ? 640 : 1080
                let r = all.first(where: { ($0.x ?? 0) >= want }) ?? all.last
                guard let u = URL(string: r?.u ?? ""), let full = URL(string: s.u ?? "") else { return nil }
                return GalleryEntry(id: it.media_id, url: u, full: full, size: CGSize(w: s.x, h: s.y), caption: it.caption, mp4: nil)
            }
            if !entries.isEmpty { return .gallery(entries) }
        }

        let poster = previewImage(target: 720)?.url
        if let rv = secure_media?.reddit_video ?? media?.reddit_video {
            return .video(VideoInfo(hls: rv.hls_url.flatMap(URL.init(string:)), mp4: rv.fallback_url.flatMap(URL.init(string:)),
                                    poster: poster, size: CGSize(w: rv.width, h: rv.height), isGif: rv.is_gif ?? false, duration: rv.duration))
        }
        if urlString.range(of: #"imgur\.com/.+\.gifv$"#, options: [.regularExpression, .caseInsensitive]) != nil,
           let mp4 = URL(string: urlString.replacingOccurrences(of: ".gifv", with: ".mp4")) {
            let src = preview?.images?.first?.source
            return .video(VideoInfo(hls: nil, mp4: mp4, poster: poster, size: CGSize(w: src?.width, h: src?.height), isGif: true, duration: nil))
        }
        if let yid = Post.youtubeID(urlString), let u = URL(string: urlString) {
            return .youtube(id: yid, url: u, thumb: previewImage(target: 720)?.url ?? URL(string: "https://i.ytimg.com/vi/\(yid)/hqdefault.jpg"))
        }
        if let pv = preview?.reddit_video_preview, pv.fallback_url != nil {
            return .video(VideoInfo(hls: pv.hls_url.flatMap(URL.init(string:)), mp4: pv.fallback_url.flatMap(URL.init(string:)),
                                    poster: poster, size: CGSize(w: pv.width, h: pv.height), isGif: true, duration: nil))
        }
        if let u = URL(string: urlString), urlString.range(of: #"\.(mp4|webm|mov|m3u8)(\?.*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let isHLS = urlString.lowercased().contains(".m3u8")
            let src = preview?.images?.first?.source
            return .video(VideoInfo(hls: isHLS ? u : nil, mp4: isHLS ? nil : u, poster: poster, size: CGSize(w: src?.width, h: src?.height), isGif: false, duration: nil))
        }
        let isImageURL = urlString.range(of: #"\.(jpe?g|png|webp|gif)(\?.*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        if post_hint == "image" || isImageURL {
            if urlString.lowercased().contains(".gif"),
               let mp4 = preview?.images?.first?.variants?.mp4?.source.flatMap({ URL(string: $0.url) }) {
                let src = preview?.images?.first?.source
                return .video(VideoInfo(hls: nil, mp4: mp4, poster: poster, size: CGSize(w: src?.width, h: src?.height), isGif: true, duration: nil))
            }
            if urlString.lowercased().contains(".gif"), let u = URL(string: urlString) {
                let src = preview?.images?.first?.source
                return .image(GalleryEntry(id: id, url: u, full: u, size: CGSize(w: src?.width, h: src?.height), caption: nil, mp4: nil))
            }
            if let img = previewImage() { return .image(img) }
            if let u = URL(string: urlString) { return .image(GalleryEntry(id: id, url: u, full: u, size: nil, caption: nil, mp4: nil)) }
        }
        if is_self == true { return .text }
        if let u = URL(string: urlString), u.scheme?.hasPrefix("http") == true {
            if let route = Route.from(url: u), case .post(let ref) = route, ref.id == id { return .text }
            return .link(url: u, domain: u.host?.replacingOccurrences(of: "www.", with: "") ?? "", thumb: thumbnailURL)
        }
        return .none
    }

    static func youtubeID(_ s: String) -> String? {
        let pattern = #"(?:youtube\.com/(?:watch\?(?:.*&)?v=|shorts/|embed/|live/)|youtu\.be/)([\w-]{11})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}

// MARK: - Inline media inside comments and text posts

enum InlineMedia {
    private static let urlRE = try! NSRegularExpression(
        pattern: #"https?://(?:i\.redd\.it|preview\.redd\.it|i\.imgur\.com|media\d?\.giphy\.com|i\.giphy\.com)/[^\s)\]]+?\.(?:jpe?g|png|webp|gif|gifv|mp4)(?:\?[^\s)\]]*)?"#,
        options: [.caseInsensitive])

    static func entries(meta: [String: MediaMeta]?, text: String?, idPrefix: String) -> [GalleryEntry] {
        var out: [GalleryEntry] = []
        var seen = Set<String>()
        for (key, m) in (meta ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard m.status == nil || m.status == "valid", let s = m.s else { continue }
            let mp4 = s.mp4.flatMap(URL.init(string:))
            guard let still = URL(string: s.gif ?? s.u ?? s.mp4 ?? "") else { continue }
            if seen.insert(still.absoluteString).inserted {
                out.append(GalleryEntry(id: idPrefix + key, url: still, full: still, size: CGSize(w: s.x, h: s.y), caption: nil, mp4: mp4))
            }
        }
        if let text {
            for match in urlRE.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(match.range, in: text) else { continue }
                var str = String(text[r])
                var mp4: URL? = nil
                if str.lowercased().hasSuffix(".gifv") { str = String(str.dropLast(5)) + ".mp4" }
                if str.lowercased().contains(".mp4") { mp4 = URL(string: str) }
                guard let u = URL(string: str), seen.insert(u.absoluteString).inserted else { continue }
                // A preview.redd.it link already covered by media_metadata shares the media id.
                if let last = u.lastPathComponent.split(separator: ".").first, out.contains(where: { $0.id.hasSuffix(String(last)) }) { continue }
                out.append(GalleryEntry(id: idPrefix + "\(out.count)", url: u, full: u, size: nil, caption: nil, mp4: mp4))
            }
        }
        return out
    }
}

extension Comment {
    var inlineMedia: [GalleryEntry] { InlineMedia.entries(meta: media_metadata, text: body, idPrefix: "c\(id)-") }
}

extension Post {
    /// Images/GIFs embedded in a text post's body.
    var inlineMedia: [GalleryEntry] {
        guard is_self == true else { return [] }
        return InlineMedia.entries(meta: media_metadata, text: selftext, idPrefix: "p\(id)-")
    }
}
