import Foundation
import CoreGraphics

// MARK: - Listing envelope

/// A Reddit "thing". Unknown or undecodable children become `.unknown` so one odd post never breaks a feed.
enum Thing: Decodable {
    case post(Post)
    case comment(Comment)
    case more(More)
    case subreddit(Subreddit)
    case user(RedditUser)
    case unknown

    private enum K: String, CodingKey { case kind, data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        switch kind {
        case "t3": self = (try? c.decode(Post.self, forKey: .data)).map(Thing.post) ?? .unknown
        case "t1": self = (try? c.decode(Comment.self, forKey: .data)).map(Thing.comment) ?? .unknown
        case "more": self = (try? c.decode(More.self, forKey: .data)).map(Thing.more) ?? .unknown
        case "t5": self = (try? c.decode(Subreddit.self, forKey: .data)).map(Thing.subreddit) ?? .unknown
        case "t2": self = (try? c.decode(RedditUser.self, forKey: .data)).map(Thing.user) ?? .unknown
        default: self = .unknown
        }
    }
}

struct ListingResponse: Decodable {
    let data: ListingData
}

struct ListingData: Decodable {
    let after: String?
    let children: [Thing]
}

struct Wrapped<T: Decodable>: Decodable {
    let data: T
}

struct MoreChildrenResponse: Decodable {
    struct J: Decodable { let data: D? }
    struct D: Decodable { let things: [Thing] }
    let json: J
}

// MARK: - Post

struct Post: Codable, Identifiable, Hashable {
    let id: String
    var name: String?
    let title: String
    var subreddit: String = ""
    var author: String = "[deleted]"
    var created_utc: Double = 0
    var score: Int?
    var num_comments: Int?
    var upvote_ratio: Double?
    var url: String?
    var url_overridden_by_dest: String?
    var permalink: String?
    var is_self: Bool?
    var selftext: String?
    var thumbnail: String?
    var domain: String?
    var over_18: Bool?
    var spoiler: Bool?
    var stickied: Bool?
    var locked: Bool?
    var link_flair_text: String?
    var link_flair_background_color: String?
    var link_flair_text_color: String?
    var post_hint: String?
    var is_video: Bool?
    var is_gallery: Bool?
    var preview: Preview?
    var media: PostMediaInfo?
    var secure_media: PostMediaInfo?
    var gallery_data: GalleryData?
    var media_metadata: [String: MediaMeta]?
    var crosspost_parent_list: [Post]?
    var distinguished: String?
    var author_fullname: String?
    /// Community details included with listings (`sr_detail=1`), so icons cost no extra request.
    var sr_detail: Subreddit?

    static func == (a: Post, b: Post) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var webURL: URL {
        URL(string: "https://www.reddit.com" + (permalink ?? "/comments/\(id)")) ?? URL(string: "https://www.reddit.com")!
    }
    var linkURL: URL? {
        guard let s = url_overridden_by_dest ?? url else { return nil }
        return URL(string: s)
    }
    var isExternalLink: Bool {
        guard is_self != true, let d = domain else { return false }
        return !(d.contains("reddit.com") || d.contains("redd.it") || d.hasPrefix("self."))
    }
    var created: Date { Date(timeIntervalSince1970: created_utc) }
    var subredditIcon: URL? { sr_detail?.iconURL ?? Library.shared.icon(for: subreddit) }
}

struct Preview: Codable {
    var images: [PreviewImage]?
    var reddit_video_preview: RedditVideo?
}

struct PreviewImage: Codable {
    var source: ImageRes?
    var resolutions: [ImageRes]?
    var variants: Variants?
}

struct Variants: Codable {
    var mp4: VariantImage?
    var gif: VariantImage?
}

struct VariantImage: Codable {
    var source: ImageRes?
}

struct ImageRes: Codable {
    var url: String
    var width: Int
    var height: Int
}

struct PostMediaInfo: Codable {
    var reddit_video: RedditVideo?
    var oembed: OEmbed?
}

struct RedditVideo: Codable {
    var fallback_url: String?
    var hls_url: String?
    var width: Int?
    var height: Int?
    var duration: Int?
    var is_gif: Bool?
}

struct OEmbed: Codable {
    var title: String?
    var thumbnail_url: String?
}

struct GalleryData: Codable {
    var items: [GalleryItem]
}

struct GalleryItem: Codable {
    var media_id: String
    var caption: String?
}

struct MediaMeta: Codable {
    var status: String?
    var e: String?
    var s: MetaSource?
    var p: [MetaSource]?
}

struct MetaSource: Codable {
    var x: Int?
    var y: Int?
    var u: String?
    var gif: String?
    var mp4: String?
}

// MARK: - Comments

/// Reddit sends `edited` as either `false` or a timestamp.
struct Flex: Decodable {
    let isTrue: Bool
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { isTrue = b }
        else if (try? c.decode(Double.self)) != nil { isTrue = true }
        else { isTrue = false }
    }
}

/// `replies` is either "" or a listing.
struct Replies: Decodable {
    let children: [Thing]
    init(from decoder: Decoder) throws {
        if let l = try? ListingResponse(from: decoder) { children = l.data.children } else { children = [] }
    }
}

struct Comment: Decodable, Identifiable {
    let id: String
    var author: String = "[deleted]"
    var body: String?
    var score: Int?
    var score_hidden: Bool?
    var created_utc: Double = 0
    var edited: Flex?
    var distinguished: String?
    var stickied: Bool?
    var is_submitter: Bool?
    var author_flair_text: String?
    var parent_id: String?
    var link_id: String?
    var link_title: String?
    var subreddit: String?
    var permalink: String?
    var replies: Replies?
    var media_metadata: [String: MediaMeta]?
    var author_fullname: String?

    var created: Date { Date(timeIntervalSince1970: created_utc) }
    var postID: String? { link_id.map { String($0.dropFirst(3)) } }
}

struct More: Decodable {
    let id: String
    var count: Int?
    var children: [String] = []
    var parent_id: String?
}

// MARK: - Subreddits & users

struct Subreddit: Codable, Identifiable {
    var id: String?
    let display_name: String
    var title: String?
    var public_description: String?
    var description: String?
    var subscribers: Int?
    var active_user_count: Int?
    var accounts_active: Int?
    var community_icon: String?
    var icon_img: String?
    var banner_background_image: String?
    var banner_img: String?
    var mobile_banner_image: String?
    var over18: Bool?
    var primary_color: String?
    var key_color: String?

    var iconURL: URL? { URL.nonEmpty(community_icon) ?? URL.nonEmpty(icon_img) }
    var bannerURL: URL? { URL.nonEmpty(banner_background_image) ?? URL.nonEmpty(mobile_banner_image) ?? URL.nonEmpty(banner_img) }
    var online: Int? { active_user_count ?? accounts_active }
}

struct RedditUser: Decodable {
    let name: String
    var icon_img: String?
    var snoovatar_img: String?
    var link_karma: Int?
    var comment_karma: Int?
    var created_utc: Double?
    var subreddit: UserSub?

    struct UserSub: Decodable {
        var title: String?
        var public_description: String?
        var banner_img: String?
    }

    var iconURL: URL? { URL.nonEmpty(snoovatar_img) ?? URL.nonEmpty(icon_img) }
    var karma: Int { (link_karma ?? 0) + (comment_karma ?? 0) }
}

extension URL {
    static func nonEmpty(_ s: String?) -> URL? {
        guard let s, !s.isEmpty, s.hasPrefix("http") else { return nil }
        return URL(string: s)
    }
}

extension CGSize {
    init?(w: Int?, h: Int?) {
        guard let w, let h, w > 0, h > 0 else { return nil }
        self.init(width: w, height: h)
    }
}
