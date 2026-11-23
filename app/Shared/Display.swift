import Foundation

/// Human-friendly labels for sources, signals and dates.
enum Display {
    static let blogNames: [String: String] = [
        "openai": "OpenAI", "deepmind": "Google DeepMind", "google_research": "Google Research",
        "meta": "Meta", "mistral": "Mistral AI", "huggingface": "Hugging Face", "nvidia": "NVIDIA",
        "anthropic": "Anthropic",
    ]

    static func source(_ s: String) -> String {
        if s.hasPrefix("blog:") {
            let key = String(s.dropFirst(5))
            return blogNames[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
        }
        switch s {
        case "arxiv": return "arXiv"
        case "hf_papers": return "Hugging Face Papers"
        case "hn": return "Hacker News"
        case "github": return "GitHub"
        default: return s
        }
    }

    /// The single most meaningful signal, e.g. "▲ 84", "855 points", "★ 3.0k".
    static func signal(_ s: Signals) -> String? {
        if s.hnPoints > 0 && s.hnPoints >= s.hfUpvotes * 5 { return "\(compact(s.hnPoints)) points" }
        if s.hfUpvotes > 0 { return "▲ \(compact(s.hfUpvotes))" }
        if s.githubStars > 0 { return "★ \(compact(s.githubStars))" }
        if s.hnPoints > 0 { return "\(compact(s.hnPoints)) points" }
        return nil
    }

    static func compact(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    // MARK: Dates. Feed days are UTC calendar days; times are shown in local time.

    static let utc = TimeZone(identifier: "UTC")!

    static func utcDayString(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func dateFromDay(_ day: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }

    /// "Today", "Yesterday", or e.g. "Mon, Nov 23".
    static func dayTitle(_ day: String, now: Date = Date()) -> String {
        if day == utcDayString(now) { return "Today" }
        if day == utcDayString(now.addingTimeInterval(-86_400)) { return "Yesterday" }
        return longDay(day)
    }

    static func longDay(_ day: String) -> String {
        guard let d = dateFromDay(day) else { return day }
        let f = DateFormatter()
        f.timeZone = utc
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f.string(from: d)
    }

    static func fullDay(_ day: String) -> String {
        guard let d = dateFromDay(day) else { return day }
        let f = DateFormatter()
        f.timeZone = utc
        f.setLocalizedDateFormatFromTemplate("EEEEMMMMdyyyy")
        return f.string(from: d)
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// Local time of an ISO timestamp, e.g. "2:41 PM".
    static func localTime(_ iso: String) -> String? {
        guard let d = parseISO(iso) else { return nil }
        return d.formatted(date: .omitted, time: .shortened)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}
