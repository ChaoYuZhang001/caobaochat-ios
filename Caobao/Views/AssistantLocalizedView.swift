import SwiftUI

extension View {
    /// Resolves a static title to a new String whenever the view locale changes,
    /// while preserving the navigation hierarchy and its existing view state.
    func assistantNavigationTitle(_ key: String) -> some View {
        modifier(AssistantNavigationTitleModifier(key: key))
    }
}

private struct AssistantNavigationTitleModifier: ViewModifier {
    let key: String
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        let title = AssistantLocalization.string(key,
            language: AssistantLocalization.resourceLanguage(for: locale), bundle: .main)
        content.navigationTitle(title)
    }
}
