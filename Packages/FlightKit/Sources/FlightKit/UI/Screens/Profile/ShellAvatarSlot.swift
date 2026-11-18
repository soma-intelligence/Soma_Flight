import SwiftUI

/// The trailing part of a tab's root header (R5) on Friends and Passport: the room the shell's
/// `ProfileButton` (the user's avatar, 44 pt) floats in. The header draws no control of its own there.
struct ShellAvatarSlot: View {
    @Environment(\.metricsScale) private var scale

    var body: some View {
        Color.clear
            .frame(width: Theme.metric(44, scale), height: Theme.metric(44, scale))
            .accessibilityHidden(true)
    }
}

extension View {
    /// A tab's root header as one VoiceOver heading that keeps the sheet's Expand and Collapse actions, as the
    /// old `ScreenTitle` offered them.
    func rootHeaderAccessibility() -> some View { modifier(RootHeaderAccessibility()) }
}

private struct RootHeaderAccessibility: ViewModifier {
    @Environment(\.sheetDetentActions) private var detentActions

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityActions {
                if let expand = detentActions?.expand { Button("Expand", action: expand) }
                if let collapse = detentActions?.collapse { Button("Collapse", action: collapse) }
            }
    }
}
