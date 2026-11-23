import Foundation

/// Mirrors the collector's JSON schema (schema_version 1). Decoding is lenient:
/// unknown categories map to `.other` and missing optional fields get defaults,
/// so a newer feed never crashes an older app.

enum DigestCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case research = "Research"
    case trainingMethod = "Training method"
    case modelRelease = "Model release"
    case tool = "Tool / Open source"
    case industry = "Industry"
    case other = "Other"

    var id: String { rawValue }

    static let known: [DigestCategory] = [.research, .trainingMethod, .modelRelease, .tool, .industry]

    /// Short label for chips.
    var short: String {
        switch self {
        case .research: "Research"
        case .trainingMethod: "Training"
        case .modelRelease: "Release"
        case .tool: "Open source"
        case .industry: "Industry"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .research: "text.book.closed"
        case .trainingMethod: "dial.medium"
        case .modelRelease: "shippingbox"
        case .tool: "hammer"
        case .industry: "building.2"
        case .other: "circle"
        }
    }
}

extension DigestCategory: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DigestCategory(rawValue: raw) ?? .other
    }
}

struct Signals: Codable, Hashable, Sendable {
    var hfUpvotes: Int = 0
    var hnPoints: Int = 0
    var githubStars: Int = 0

    init(hfUpvotes: Int = 0, hnPoints: Int = 0, githubStars: Int = 0) {
        self.hfUpvotes = hfUpvotes
        self.hnPoints = hnPoints
        self.githubStars = githubStars
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hfUpvotes = try c.decodeIfPresent(Int.self, forKey: .hfUpvotes) ?? 0
        hnPoints = try c.decodeIfPresent(Int.self, forKey: .hnPoints) ?? 0
        githubStars = try c.decodeIfPresent(Int.self, forKey: .githubStars) ?? 0
    }
}

struct DigestItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var url: String
    var source: String
    var category: DigestCategory
    var summary: String
    var whyItMatters: String
    var score: Double
    var signals: Signals
    var publishedAt: String
    var summarizedBy: String?
    var summaryStatus: String

    var isPending: Bool { summaryStatus != "done" }
    var link: URL? { URL(string: url) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        category = try c.decodeIfPresent(DigestCategory.self, forKey: .category) ?? .other
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        whyItMatters = try c.decodeIfPresent(String.self, forKey: .whyItMatters) ?? ""
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        signals = try c.decodeIfPresent(Signals.self, forKey: .signals) ?? Signals()
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt) ?? ""
        summarizedBy = try c.decodeIfPresent(String.self, forKey: .summarizedBy)
        summaryStatus = try c.decodeIfPresent(String.self, forKey: .summaryStatus) ?? "pending"
    }
}

struct MoreItem: Codable, Identifiable, Hashable, Sendable {
    var title: String
    var url: String
    var source: String
    var category: DigestCategory
    var id: String { url }

    var link: URL? { URL(string: url) }
}

struct DayDigest: Codable, Identifiable, Hashable, Sendable {
    var schemaVersion: Int
    var date: String              // UTC day, "YYYY-MM-DD"
    var generatedAt: String
    var headline: String
    var headlineStatus: String?
    var items: [DigestItem]
    var more: [MoreItem]

    var id: String { date }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        date = try c.decode(String.self, forKey: .date)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt) ?? ""
        headline = try c.decodeIfPresent(String.self, forKey: .headline) ?? ""
        headlineStatus = try c.decodeIfPresent(String.self, forKey: .headlineStatus)
        items = try c.decodeIfPresent([DigestItem].self, forKey: .items) ?? []
        more = try c.decodeIfPresent([MoreItem].self, forKey: .more) ?? []
    }
}

struct IndexDay: Codable, Hashable, Sendable {
    var date: String
    var headline: String?
    var itemCount: Int?
    var generatedAt: String?
}

struct FeedIndex: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var generatedAt: String
    var latest: String
    var days: [IndexDay]
}

enum FeedJSON {
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
