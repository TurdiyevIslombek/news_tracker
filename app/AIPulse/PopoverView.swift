import AppKit
import SwiftUI

@MainActor final class PopoverState: ObservableObject {
    @Published var selectedDate: String?          // nil = latest
    @Published var category: DigestCategory?       // nil = all
    @Published var query = ""
    @Published var showCalendar = false
    @Published var showMore = false
}

struct PopoverView: View {
    @EnvironmentObject private var store: FeedStore
    @StateObject private var ui: PopoverState

    init(initialState: PopoverState = PopoverState()) {
        _ui = StateObject(wrappedValue: initialState)
    }
    @FocusState private var searchFocused: Bool

    private var selectedDate: String? { ui.selectedDate }
    private var category: DigestCategory? { ui.category }
    private var query: String { ui.query }

    private var dates: [String] { store.availableDates }
    private var currentDate: String? { selectedDate ?? store.latestDate }
    private var digest: DayDigest? { currentDate.flatMap(store.digest(for:)) }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchAndFilter
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 420, height: 620)
        .task(id: currentDate) {
            if let d = currentDate { await store.ensureLoaded(d) }
        }
        .onAppear {
            // Opening the popover is a good moment to catch up if it's been a while.
            if Date().timeIntervalSince(store.lastRefresh ?? .distantPast) > 1800 {
                Task { await store.refresh() }
            }
        }
    }

    // MARK: Header with day navigation

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("AI PULSE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(currentDate.map { Display.dayTitle($0) } ?? "Welcome")
                    .font(.system(size: 20, weight: .bold))
                    .contentTransition(.numericText())
                if let d = currentDate, Display.dayTitle(d) != Display.longDay(d) {
                    Text(Display.longDay(d)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 2) {
                NavButton(symbol: "chevron.left", help: "Previous day", disabled: olderDate == nil) {
                    go(to: olderDate)
                }
                NavButton(symbol: "calendar", help: "Pick a day", disabled: dates.isEmpty) {
                    ui.showCalendar.toggle()
                }
                .popover(isPresented: $ui.showCalendar, arrowEdge: .bottom) { calendar }
                NavButton(symbol: "chevron.right", help: "Next day", disabled: newerDate == nil) {
                    go(to: newerDate)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var olderDate: String? {
        guard let c = currentDate, let i = dates.firstIndex(of: c), i + 1 < dates.count else { return nil }
        return dates[i + 1]
    }

    private var newerDate: String? {
        guard let c = currentDate, let i = dates.firstIndex(of: c), i > 0 else { return nil }
        return dates[i - 1]
    }

    private func go(to date: String?) {
        guard let date else { return }
        withAnimation(.snappy(duration: 0.2)) {
            ui.selectedDate = date == store.latestDate ? nil : date
            ui.showMore = false
        }
    }

    private var calendar: some View {
        let utc = Display.utc
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let available = dates.compactMap(Display.dateFromDay)
        let range = (available.min() ?? Date())...(available.max() ?? Date())
        let binding = Binding<Date>(
            get: { currentDate.flatMap(Display.dateFromDay) ?? Date() },
            set: { picked in
                let key = Display.utcDayString(picked)
                if dates.contains(key) { go(to: key); ui.showCalendar = false }
            }
        )
        return VStack(alignment: .leading, spacing: 8) {
            DatePicker("Day", selection: binding, in: range, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .environment(\.timeZone, utc)
                .environment(\.calendar, cal)
            Text("\(dates.count) days available · dates are UTC")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: Search + category filter

    private var searchAndFilter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField("Search all saved days", text: $ui.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { ui.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(title: "All", color: .primary, isOn: category == nil) { ui.category = nil }
                    ForEach(DigestCategory.known) { c in
                        FilterChip(title: c.short, color: c.color, count: count(c), isOn: category == c) {
                            ui.category = category == c ? nil : c
                        }
                    }
                }
                .padding(.horizontal, 2).padding(.vertical, 1)   // room for the selected chip border
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func count(_ c: DigestCategory) -> Int? {
        guard !isSearching, let digest else { return nil }
        let n = digest.items.filter { $0.category == c }.count
        return n > 0 ? n : nil
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if isSearching {
            searchResults
        } else if let digest {
            dayView(digest)
        } else if store.isRefreshing {
            Placeholder(symbol: "arrow.down.circle", title: "Loading today's digest…")
        } else {
            Placeholder(symbol: "wifi.slash", title: "No saved days yet",
                        detail: store.lastError ?? "Connect to the internet to download the feed.",
                        action: ("Try again", { Task { await store.refresh() } }))
        }
    }

    private func dayView(_ digest: DayDigest) -> some View {
        let items = digest.items.filter { category == nil || $0.category == category }
        let more = digest.more.filter { category == nil || $0.category == category }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if category == nil, !digest.headline.isEmpty {
                    HeadlineCard(text: digest.headline, pending: digest.headlineStatus == "pending",
                                 isToday: Display.dayTitle(digest.date) == "Today")
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                }
                if items.isEmpty {
                    Text("Nothing in this category today.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                }
                ForEach(items) { item in
                    ItemRow(item: item)
                    if item.id != items.last?.id { Divider().padding(.leading, 16).opacity(0.5) }
                }
                if !more.isEmpty {
                    MoreSection(items: more, expanded: $ui.showMore)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var searchResults: some View {
        let hits = store.search(query, category: category)
        let grouped = Dictionary(grouping: hits, by: \.date)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if hits.isEmpty {
                    Text("No matches in \(store.days.count) saved days.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                ForEach(grouped.keys.sorted(by: >), id: \.self) { date in
                    Section {
                        ForEach(grouped[date] ?? []) { hit in ItemRow(item: hit.item) }
                    } header: {
                        Text(Display.dayTitle(date) == Display.longDay(date)
                             ? Display.longDay(date) : "\(Display.dayTitle(date)) · \(Display.longDay(date))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.bar)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if store.isRefreshing {
                ProgressView().controlSize(.small)
                Text("Updating…")
            } else if let err = store.lastError {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(err).lineLimit(1).help(err)
            } else if let last = store.lastRefresh {
                Text("Updated \(Display.relative(last))")
            } else if let gen = digest.flatMap({ Display.parseISO($0.generatedAt) }) {
                Text("Saved copy from \(Display.relative(gen))")
            }
            Spacer()
            FooterButton(symbol: "arrow.clockwise", help: "Refresh now") { Task { await store.refresh() } }
                .disabled(store.isRefreshing)
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Settings")
            FooterButton(symbol: "power", help: "Quit AI Pulse") { NSApp.terminate(nil) }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Pieces

private struct NavButton: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void
    @StateObject private var hover = Flag()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(hover.on && !disabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? .tertiary : .secondary)
        .disabled(disabled)
        .onHover { hover.on = $0 }
        .help(help)
    }
}

private struct FooterButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct FilterChip: View {
    let title: String
    let color: Color
    var count: Int? = nil
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if color != .primary { Circle().fill(color).frame(width: 6, height: 6) }
                Text(title)
                if let count { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            }
            .font(.system(size: 11, weight: isOn ? .semibold : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(isOn ? AnyShapeStyle(color.opacity(color == .primary ? 0.12 : 0.18))
                             : AnyShapeStyle(.quaternary.opacity(0.5)),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? color.opacity(0.35) : .clear, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

private struct HeadlineCard: View {
    let text: String
    let pending: Bool
    var isToday = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                Text((isToday ? "TODAY IN AI" : "THE DAY IN AI") + (pending ? " · SUMMARY PENDING" : ""))
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6)
            }
            .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(.primary.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MoreSection: View {
    let items: [MoreItem]
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    Text("More (\(items.count))").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(items) { m in
                    Button {
                        if let u = m.link { NSWorkspace.shared.open(u) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(m.category.color).frame(width: 5, height: 5)
                            Text(m.title).font(.system(size: 12)).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Display.source(m.source)).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 16).padding(.vertical, 5)
                    }
                    .buttonStyle(HoverRowStyle())
                }
            }
        }
        .padding(.top, 4)
    }
}

private struct Placeholder: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var action: (String, () -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if let action { Button(action.0, action: action.1).controlSize(.small) }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
