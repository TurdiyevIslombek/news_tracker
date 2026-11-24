import SwiftUI
import WidgetKit

/// Opens the app and its popover (tapping anywhere that isn't a story).
let openAppURL = URL(string: "aipulse://open")!

// Widgets can't scroll, and the exact size varies by Mac and display, so each layout
// offers a few arrangements (most detailed first) and ViewThatFits picks the first
// one that fits. Anything left over is one tap away in the popover ("+N more").

private enum Metrics {
    static let hPad: CGFloat = 16
    static let vPad: CGFloat = 14
}

struct DigestWidgetView: View {
    let entry: DigestEntry
    var familyOverride: WidgetFamily? = nil      // for offscreen previews outside WidgetKit
    @Environment(\.widgetFamily) private var envFamily
    private var family: WidgetFamily { familyOverride ?? envFamily }

    var body: some View {
        Group {
            if let digest = entry.digest {
                switch family {
                case .systemSmall: SmallView(digest: digest, now: entry.date)
                case .systemLarge: LargeView(digest: digest, now: entry.date)
                default: MediumView(digest: digest, now: entry.date)
                }
            } else {
                EmptyStateView()
            }
        }
        .redacted(reason: entry.isSample && entry.digest == nil ? .placeholder : [])
        .containerBackground(.background, for: .widget)
    }
}

// MARK: Header: "✦ AI PULSE · Today            +12 more"

private struct Header: View {
    let digest: DayDigest
    let now: Date
    let shown: Int

    var body: some View {
        Link(destination: openAppURL) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.indigo)
                    .widgetAccentable()
                Text("AI PULSE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary).font(.system(size: 10))
                Text(Display.dayTitle(digest.date, now: now))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                MoreBadge(remaining: digest.items.count - shown)
            }
            .lineLimit(1)
        }
        .buttonStyle(.plain)
    }
}

private struct MoreBadge: View {
    let remaining: Int

    var body: some View {
        if remaining > 0 {
            HStack(spacing: 2) {
                Text("+\(remaining) more")
                Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
    }
}

// MARK: Small: day + headline + story count. Whole widget opens the app.

private struct SmallView: View {
    let digest: DayDigest
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.indigo)
                    .widgetAccentable()
                Text("AI PULSE")
                    .font(.system(size: 10, weight: .bold)).tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            Text(Display.dayTitle(digest.date, now: now))
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
            ViewThatFits(in: .vertical) {
                headline(lines: 5)
                headline(lines: 4)
                headline(lines: 3)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(categories, id: \.self) { c in
                    Circle().fill(c.color).frame(width: 6, height: 6).widgetAccentable()
                }
                Spacer(minLength: 2)
                Text("\(digest.items.count) stories")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, Metrics.vPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(openAppURL)
    }

    private func headline(lines: Int) -> some View {
        Text(digest.headline.isEmpty ? (digest.items.first?.title ?? "") : digest.headline)
            .font(.system(size: 11.5))
            .foregroundStyle(.primary.opacity(0.85))
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var categories: [DigestCategory] {
        DigestCategory.known.filter { c in digest.items.contains { $0.category == c } }
    }
}

// MARK: Medium: top 3

private struct MediumView: View {
    let digest: DayDigest
    let now: Date

    var body: some View {
        ViewThatFits(in: .vertical) {
            layout(count: 3, twoLine: 3)
            layout(count: 3, twoLine: 2)
            layout(count: 3, twoLine: 1)
            layout(count: 3, twoLine: 0)
            layout(count: 2, twoLine: 0)
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, Metrics.vPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func layout(count: Int, twoLine: Int) -> some View {
        let items = Array(digest.items.prefix(count))
        return VStack(alignment: .leading, spacing: 7) {
            Header(digest: digest, now: now, shown: items.count)
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                ItemLine(item: item, titleLines: i < twoLine ? 2 : 1)
            }
        }
    }
}

// MARK: Large: headline + top 6

private struct LargeView: View {
    let digest: DayDigest
    let now: Date

    var body: some View {
        // Top 6 always; the first n get two-line titles, n shrinking until it fits.
        ViewThatFits(in: .vertical) {
            layout(count: 6, twoLine: 6, headlineLines: 3)
            ForEach(Array(stride(from: 6, through: 0, by: -1)), id: \.self) { n in
                layout(count: 6, twoLine: n, headlineLines: 2)
            }
            layout(count: 5, twoLine: 0, headlineLines: 2)
            layout(count: 4, twoLine: 0, headlineLines: 1)
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, Metrics.vPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func layout(count: Int, twoLine: Int, headlineLines: Int) -> some View {
        let items = Array(digest.items.prefix(count))
        return VStack(alignment: .leading, spacing: 0) {
            Header(digest: digest, now: now, shown: items.count)
            if !digest.headline.isEmpty {
                Link(destination: openAppURL) {
                    Text(digest.headline)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(headlineLines)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            Divider().padding(.vertical, 9)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    ItemLine(item: item, titleLines: i < twoLine ? 2 : 1)
                }
            }
        }
    }
}

// MARK: One story: category bar, title, "Research · Hugging Face Papers · ▲ 84"

private struct ItemLine: View {
    let item: DigestItem
    var titleLines = 2

    var body: some View {
        Link(destination: item.link ?? openAppURL) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(item.category.color)
                    .frame(width: 3)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(titleLines)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Text(item.category.short)
                            .foregroundStyle(item.category.color)
                            .widgetAccentable()
                        Text("·")
                        Text(Display.source(item.source))
                        if let sig = Display.signal(item.signals) {
                            Text("·")
                            Text(sig).monospacedDigit()
                        }
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)   // links look like content, not blue hyperlinks
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(Color.indigo).widgetAccentable()
            Text("AI Pulse").font(.system(size: 13, weight: .semibold))
            Text("Connect to the internet to load today's digest.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(Metrics.hPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(openAppURL)
    }
}
