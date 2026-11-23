import SwiftUI

// The Command Line Tools ship without the SwiftUIMacros compiler plugin, and in this
// SDK `@State` is a macro. Small ObservableObjects held by `@StateObject` do the same
// job, so the app builds with or without Xcode.

/// A boolean view-local flag (hover, expanded, presented).
@MainActor final class Flag: ObservableObject {
    @Published var on: Bool
    init(_ on: Bool = false) { self.on = on }
}

/// A string view-local value (text field drafts).
@MainActor final class TextBox: ObservableObject {
    @Published var text: String
    init(_ text: String = "") { self.text = text }
}
