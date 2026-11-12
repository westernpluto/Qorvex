import Foundation

/// Example content shown while signed out. Generated locally — nothing is requested from Reddit.
enum SampleData {
    private static let raw: [(sub: String, author: String, title: String, text: String, score: Int, comments: Int, hours: Double, flair: String?)] = [
        ("photography", "lumen_and_dust", "Golden hour over the harbor after a week of rain", "Shot handheld at 1/250. The light only lasted about four minutes.", 18_400, 312, 3, "Landscape"),
        ("technology", "circuit_sage", "Researchers demo a battery that charges to 80% in five minutes", "The prototype uses a new silicon-carbon anode. Commercial cells are still a few years out.", 9_820, 1_204, 5, "Energy"),
        ("AskReddit", "quiet_question", "What's a small habit that genuinely improved your life?", "", 24_100, 8_930, 7, nil),
        ("space", "orbit_notes", "The new deep-field image shows galaxies from 13 billion years ago", "Every dot in this image is a galaxy. Some of the light left them before Earth existed.", 31_600, 1_870, 9, "Image"),
        ("cooking", "salt_and_steel", "I finally nailed a crispy-skin salmon — here's what made the difference", "Dry the skin thoroughly, cold pan, press for the first 30 seconds, and don't touch it.", 6_340, 402, 12, "Recipe"),
        ("gaming", "pixel_wander", "Ten years later, this level design still holds up", "", 15_900, 980, 14, "Discussion"),
        ("dataisbeautiful", "chart_whisperer", "[OC] Where the world's coffee comes from, by volume", "Data from 2025 trade reports, visualized as a flow map.", 11_200, 655, 16, "OC"),
        ("aww", "paws_and_patience", "He insists on supervising every work call", "", 42_800, 760, 18, nil),
        ("science", "lab_coat_larry", "Study finds a 20-minute walk measurably improves focus for hours", "Participants showed better attention scores for up to three hours afterward.", 13_700, 1_120, 21, "Health"),
        ("EarthPorn", "trail_and_tripod", "Morning fog rolling through the valley [4000×2667]", "", 27_300, 540, 23, nil),
        ("todayilearned", "fact_finder_9", "TIL octopuses have three hearts and blue blood", "Two hearts pump blood to the gills, and one pumps it to the rest of the body.", 19_500, 1_390, 26, nil),
        ("movies", "reel_thoughts", "What's a film you think deserves a second look?", "", 8_650, 3_210, 30, "Discussion"),
    ]

    private static let commentTexts = [
        "This is genuinely one of the best things I've seen on here this week.",
        "Saving this. The detail in it is incredible.",
        "Came here to say exactly this. Glad I'm not the only one.",
        "Does anyone have a source for this? Would love to read more.",
        "Honestly the comments are as good as the post.",
        "I tried this last month and it really does make a difference.",
        "Underrated take. More people should know about this.",
    ]

    static func posts(for source: FeedSource) -> [Post] {
        let forcedSub = source.subredditName
        return raw.enumerated().compactMap { i, r in
            post(id: "sample\(i)", sub: forcedSub ?? r.sub, author: r.author, title: r.title, text: r.text,
                 score: r.score, comments: r.comments, hours: r.hours, flair: r.flair)
        }
    }

    static func isSample(_ id: String) -> Bool { id.hasPrefix("sample") }

    private static func post(id: String, sub: String, author: String, title: String, text: String, score: Int, comments: Int, hours: Double, flair: String?) -> Post? {
        var d: [String: Any] = [
            "id": id, "name": "t3_\(id)", "title": title, "subreddit": sub, "author": author,
            "created_utc": Date().timeIntervalSince1970 - hours * 3600,
            "score": score, "num_comments": comments, "is_self": true, "selftext": text,
            "permalink": "/r/\(sub)/comments/\(id)/", "domain": "self.\(sub)", "upvote_ratio": 0.96,
        ]
        if let flair { d["link_flair_text"] = flair }
        guard let data = try? JSONSerialization.data(withJSONObject: d) else { return nil }
        return try? JSONDecoder().decode(Post.self, from: data)
    }

    static func comments(author op: String) -> [CommentNode] {
        let authors = ["morning_owl", "quiet_reader", "late_to_the_party", op, "curious_cat_42", "night_shift_ned", "stats_and_tea"]
        var nodes: [CommentNode] = []
        for i in 0..<9 {
            let depth = [0, 1, 2, 0, 1, 0, 1, 1, 0][i]
            let body = commentTexts[i % commentTexts.count]
            let d: [String: Any] = [
                "id": "samplec\(i)", "author": authors[i % authors.count], "body": body,
                "score": [1_204, 386, 92, 871, 140, 512, 77, 45, 230][i],
                "created_utc": Date().timeIntervalSince1970 - Double(i + 1) * 1800,
                "is_submitter": authors[i % authors.count] == op,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: d),
                  let c = try? JSONDecoder().decode(Comment.self, from: data) else { continue }
            nodes.append(CommentNode(id: c.id, kind: .comment(c, Markdown.parse(body)), depth: depth))
        }
        return nodes
    }
}
