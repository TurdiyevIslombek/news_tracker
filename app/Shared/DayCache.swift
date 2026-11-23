import Foundation

/// Local copy of the feed: one JSON file per day plus the index, for offline browsing.
/// Phase 5 keeps it in Application Support. (Touching an App Group container without
/// the entitlement triggers a privacy prompt on recent macOS; the widget phase moves
/// this into the shared group container once entitlements exist.)
struct DayCache: Sendable {
    let dir: URL

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AI Pulse/Feed", isDirectory: true)
    }

    init(dir: URL = DayCache.defaultDirectory()) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("days"),
                                                 withIntermediateDirectories: true)
    }

    private func dayURL(_ date: String) -> URL { dir.appendingPathComponent("days/\(date).json") }
    private var indexURL: URL { dir.appendingPathComponent("index.json") }

    func load(_ date: String) -> DayDigest? {
        guard let data = try? Data(contentsOf: dayURL(date)) else { return nil }
        return try? FeedJSON.decoder().decode(DayDigest.self, from: data)
    }

    func loadAll() -> [String: DayDigest] {
        var out: [String: DayDigest] = [:]
        for date in dates() { if let d = load(date) { out[date] = d } }
        return out
    }

    func dates() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("days").path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted(by: >)
    }

    func loadIndex() -> FeedIndex? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? FeedJSON.decoder().decode(FeedIndex.self, from: data)
    }

    func save(_ day: DayDigest) throws {
        try FeedJSON.encoder().encode(day).write(to: dayURL(day.date), options: .atomic)
    }

    func save(_ index: FeedIndex) throws {
        try FeedJSON.encoder().encode(index).write(to: indexURL, options: .atomic)
    }
}
