import Foundation

// Tiny test runner for the shared code (works with just the Command Line Tools):
//   app/scripts/test.sh

nonisolated(unsafe) var failures = 0
func check(_ ok: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if ok() { print("  ✓ \(msg)") } else { failures += 1; print("  ✗ \(msg) (line \(line))") }
}

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])

print("decoding")
let dayData = try Data(contentsOf: fixtures.appendingPathComponent("day.json"))
let day = try FeedJSON.decoder().decode(DayDigest.self, from: dayData)
check(day.date == "2026-11-23", "day date")
check(!day.items.isEmpty, "items decoded (\(day.items.count))")
check(day.items.allSatisfy { !$0.title.isEmpty && $0.link != nil }, "every item has a title and a valid URL")
check(day.items.contains { $0.category != .other }, "known categories map to enum cases")
let idx = try FeedJSON.decoder().decode(FeedIndex.self, from: Data(contentsOf: fixtures.appendingPathComponent("index.json")))
check(idx.latest == idx.days.first?.date, "index latest is first day")

print("lenient decoding")
let future = #"{"date":"2030-01-01","items":[{"id":"x","title":"T","url":"https://e.com","category":"Robotics","new_field":1}]}"#
let f = try FeedJSON.decoder().decode(DayDigest.self, from: Data(future.utf8))
check(f.items.first?.category == .other, "unknown category → .other")
check(f.items.first?.isPending == true, "missing summary_status → pending")
check(f.more.isEmpty && f.headline.isEmpty, "missing fields get defaults")

print("cache round-trip")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aipulse-test-\(UUID().uuidString)")
let cache = DayCache(dir: tmp)
try cache.save(day)
try cache.save(idx)
let back = cache.load(day.date)
check(back == day, "day survives save/load")
check(cache.dates() == [day.date], "dates() lists saved days")
check(cache.loadIndex() == idx, "index survives save/load")
try? FileManager.default.removeItem(at: tmp)

print("display")
check(Display.source("blog:openai") == "OpenAI", "blog source label")
check(Display.source("hn") == "Hacker News", "hn label")
check(Display.signal(Signals(hfUpvotes: 84)) == "▲ 84", "upvote signal")
check(Display.signal(Signals(githubStars: 3016)) == "★ 3.0k", "star signal")
check(Display.signal(Signals(hfUpvotes: 2, hnPoints: 855)) == "855 points", "HN points dominate")
let noon = Display.parseISO("2026-11-23T12:00:00Z")!
check(Display.dayTitle("2026-11-23", now: noon) == "Today", "today label (UTC)")
check(Display.dayTitle("2026-11-22", now: noon) == "Yesterday", "yesterday label")
check(Display.utcDayString(noon) == "2026-11-23", "utc day string")

print(failures == 0 ? "\nall tests passed" : "\n\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
