import SwiftUI
import WidgetKit

/// Opens the app (and its popover) from the widget header.
let openAppURL = URL(string: "aipulse://open")!

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
                case .systemLarge: ListView(digest: digest, now: entry.date, count: 6, showHeadline: true)
                default: ListView(digest: digest, now: entry.date, count: 3, showHeadline: false)
                }
            } else {
                EmptyStateView()
            }
        }
        .redacted(reason: entry.isSample && entry.digest == nil ? .placeholder : [])
        .containerBackground(.background, for: .widget)
    }
}

// MARK: Header

private struct Header: View {
    let digest: DayDigest
    let now: Date
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.indigo)
                .widgetAccentable()
            Text("AI PULSE")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            if !compact {
                Text("·").foregroundStyle(.tertiary).font(.system(size: 10))
                Text(Display.dayTitle(digest.date, now: now))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if !compact {
                Text("\(digest.items.count) stories")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
    }
}

// MARK: Small — headline + item count

private struct SmallView: View {
    let digest: DayDigest
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(digest: digest, now: now, compact: true)
            Text(Display.dayTitle(digest.date, now: now))
                .font(.system(size: 15, weight: .bold))
            Text(digest.headline.isEmpty ? (digest.items.first?.title ?? "") : digest.headline)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(5)
                .minimumScaleFactor(0.9)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(categoryCounts, id: \.0) { cat, _ in
                    Circle().fill(cat.color).frame(width: 6, height: 6).widgetAccentable()
                }
                Spacer(minLength: 2)
                Text("\(digest.items.count) stories")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .widgetURL(openAppURL)
    }

    private var categoryCounts: [(DigestCategory, Int)] {
        DigestCategory.known.compactMap { c in
            let n = digest.items.filter { $0.category == c }.count
            return n > 0 ? (c, n) : nil
        }
    }
}

// MARK: Medium (top 3) and Large (headline + top 6)

private struct ListView: View {
    let digest: DayDigest
    let now: Date
    let count: Int
    let showHeadline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Link(destination: openAppURL) {
                Header(digest: digest, now: now)
            }
            .buttonStyle(.plain)
            .padding(.bottom, showHeadline ? 8 : 6)

            if showHeadline, !digest.headline.isEmpty {
                Link(destination: openAppURL) {
                    Text(digest.headline)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Divider().padding(.vertical, 8)
            }

            VStack(alignment: .leading, spacing: showHeadline ? 9 : 7) {
                ForEach(Array(digest.items.prefix(count))) { item in
                    ItemLine(item: item)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct ItemLine: View {
    let item: DigestItem

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
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
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
        .padding(14)
        .widgetURL(openAppURL)
    }
}
