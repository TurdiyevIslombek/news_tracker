import SwiftUI

extension DigestCategory {
    /// Subtle accent per category; system colors adapt to light/dark mode.
    var color: Color {
        switch self {
        case .research: .indigo
        case .trainingMethod: .teal
        case .modelRelease: .orange
        case .tool: .green
        case .industry: .pink
        case .other: .gray
        }
    }
}

struct CategoryChip: View {
    let category: DigestCategory
    var compact = false

    var body: some View {
        Text(category.short)
            .font(.system(size: compact ? 9.5 : 10, weight: .semibold))
            .foregroundStyle(category.color)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, 2)
            .background(category.color.opacity(0.13), in: Capsule())
            .accessibilityLabel(category.rawValue)
    }
}
