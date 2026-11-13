import Foundation
import Observation

/// User profile pictures, fetched in one batched request per thread and cached on disk.
@MainActor @Observable
final class AvatarStore {
    static let shared = AvatarStore()
    private(set) var urls: [String: String] = [:]          // lowercased username → image URL
    @ObservationIgnored private var tried = Set<String>()   // fullnames already requested
    @ObservationIgnored private var batchFailed = false
    @ObservationIgnored private var singleTried = Set<String>()
    @ObservationIgnored private var singleBudget = 30      // per launch, for the fallback path
    @ObservationIgnored private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("avatars.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL), let map = try? JSONDecoder().decode([String: String].self, from: data) {
            urls = map
        }
    }

    func url(for name: String) -> URL? { urls[name.lowercased()].flatMap(URL.init(string:)) }

    func remember(_ name: String, _ url: URL?) {
        guard let url, urls[name.lowercased()] != url.absoluteString else { return }
        urls[name.lowercased()] = url.absoluteString
    }

    /// Fetch pictures for any of these (fullname, username) pairs we don't know yet.
    func ensure(_ pairs: [(fullname: String, name: String)]) async {
        guard NetworkStatus.shared.signedIn || AppSettings.shared.apiActive else { return }
        let missing = pairs.filter { urls[$0.name.lowercased()] == nil && !tried.contains($0.fullname) && $0.fullname.hasPrefix("t2_") }
        guard !missing.isEmpty else { return }
        var ids: [String] = []
        for p in missing where !ids.contains(p.fullname) { ids.append(p.fullname) }
        // Top of the thread first; replies loaded later ask for their own authors.
        if ids.count > 50 { ids = Array(ids.prefix(50)) }
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            chunk.forEach { tried.insert($0) }
            guard let found = try? await Reddit.userData(ids: chunk), !found.isEmpty else { batchFailed = true; continue }
            for (_, info) in found {
                guard let name = info.name, let img = info.profile_img, !img.isEmpty, img.hasPrefix("http") else { continue }
                urls[name.lowercased()] = img
            }
        }
        persist()
    }

    /// Fallback when the batch lookup isn't available: fetch one visible commenter's picture via
    /// their profile (the same lookup profile pages use). Capped per launch and cached on disk.
    func ensureSingle(_ name: String) async {
        guard batchFailed, singleBudget > 0, name != "[deleted]", urls[name.lowercased()] == nil,
              !singleTried.contains(name.lowercased()), NetworkStatus.shared.signedIn || AppSettings.shared.apiActive else { return }
        singleTried.insert(name.lowercased())
        singleBudget -= 1
        if let u = try? await Reddit.user(name), let img = u.iconURL {
            urls[name.lowercased()] = img.absoluteString
            persist()
        }
    }

    private func persist() {
        let snapshot = urls
        let file = fileURL
        Task.detached(priority: .utility) { try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic) }
    }
}

struct UserDataInfo: Decodable {
    var name: String?
    var profile_img: String?
}
