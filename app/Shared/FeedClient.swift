import Foundation

enum FeedConfig {
    /// The public feed. Anyone running their own collector can change it in Settings.
    static let defaultFeedURL = "https://turdiyevislombek.github.io/news_tracker/"
    /// How many past days to download the first time (older days load on demand).
    static let catchUpDays = 60
}

enum FeedError: LocalizedError {
    case badURL
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: "The feed URL isn't valid."
        case .http(let code): "The feed returned HTTP \(code)."
        }
    }
}

/// Downloads the static JSON feed. No keys, no LLM calls: just GETs.
struct FeedClient: Sendable {
    let base: URL
    let session: URLSession

    init?(feedURL: String) {
        var s = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasSuffix("/") { s += "/" }
        guard let url = URL(string: s), url.scheme == "https" || url.scheme == "http" else { return nil }
        base = url
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["User-Agent": "AIPulse-mac/0.1"]
        session = URLSession(configuration: cfg)
    }

    private func get<T: Decodable>(_ path: String, bust: String) async throws -> T {
        // GitHub Pages' CDN caches for ~10 min; a query string gets a fresh copy.
        guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw FeedError.badURL }
        comps.queryItems = [URLQueryItem(name: "v", value: bust)]
        guard let url = comps.url else { throw FeedError.badURL }
        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw FeedError.http(http.statusCode) }
        return try FeedJSON.decoder().decode(T.self, from: data)
    }

    func index() async throws -> FeedIndex {
        try await get("index.json", bust: String(Int(Date().timeIntervalSince1970 / 60)))
    }

    /// `version` is the day's generated_at from the index, so unchanged days stay cacheable.
    func day(_ date: String, version: String?) async throws -> DayDigest {
        try await get("days/\(date).json", bust: version ?? String(Int(Date().timeIntervalSince1970)))
    }
}
