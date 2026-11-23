import AppKit
import SwiftUI

/// One digest item. Click opens the link; hovering reveals the full text.
struct ItemRow: View {
    let item: DigestItem
    @StateObject private var hoverState = Flag()
    private var hover: Bool { hoverState.on }

    var body: some View {
        Button {
            if let url = item.link { NSWorkspace.shared.open(url) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    CategoryChip(category: item.category)
                    if item.isPending {
                        Text("Summary pending")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                    }
                    Spacer(minLength: 4)
                    if let sig = Display.signal(item.signals) {
                        Text(sig).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(hover ? 4 : 2)
                    .multilineTextAlignment(.leading)
                Text(item.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(hover ? 10 : 3)
                    .lineSpacing(1.5)
                    .multilineTextAlignment(.leading)
                if !item.whyItMatters.isEmpty {
                    (Text("Why it matters  ").font(.system(size: 11, weight: .semibold))
                        + Text(item.whyItMatters).font(.system(size: 11)))
                        .foregroundStyle(item.category.color.opacity(0.9))
                        .lineLimit(hover ? 4 : 2)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 4) {
                    Text(Display.source(item.source))
                    if let t = Display.localTime(item.publishedAt) { Text("·"); Text(t) }
                    Spacer()
                    if hover {
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hoverState.on = h } }
        .help(item.url)
        .contextMenu {
            Button("Open Link") { if let u = item.link { NSWorkspace.shared.open(u) } }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
            if let by = item.summarizedBy { Text("Summarized by \(by)") }
        }
    }
}

/// Subtle hover/press highlight, like native list rows.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        @StateObject private var hoverState = Flag()
        private var hover: Bool { hoverState.on }

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.primary.opacity(configuration.isPressed ? 0.09 : hover ? 0.05 : 0))
                        .padding(.horizontal, 6)
                )
                .onHover { hoverState.on = $0 }
        }
    }
}
