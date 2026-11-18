import SwiftUI

// Contract
// - Name: `LoadingButtonStyle`, `.loadingButton(isLoading:variant:)` (E4, I14).
// - Use: every button that starts a network call (Accept, Decline, Send Code, Verify, Save). Pair it with an
//   in-flight guard in the store so a second tap cannot send twice.
// - Variants: `.filled` (accent capsule, white label: the screen's main action), `.tinted` (grey pill, accent
//   label: a row action such as Accept), `.plain` (the label alone, for a toolbar).
// - States: normal; pressed (70 %); disabled (45 %); loading = the label kept but hidden, so the width never
//   jumps, a ProgressView over it, and the button disabled.
// - Tokens: Theme.accent, Theme.accentText, Theme.pill, 44 pt min height, Theme.Space.md side padding.
// - A11y: while loading, VoiceOver keeps the label and reads the value "In progress"; the button is
//   disabled so a double tap does nothing.
// - Reduce Motion: the spinner is the system one; no other motion.
// - Previews: below.

/// A button style that holds its width while it shows a spinner. Use `.loadingButton(isLoading:variant:)`,
/// which also disables the button while `isLoading`.
public struct LoadingButtonStyle: ButtonStyle {
    public enum Variant: Sendable { case filled, tinted, plain }

    var isLoading: Bool
    var variant: Variant

    public init(isLoading: Bool, variant: Variant = .tinted) {
        self.isLoading = isLoading; self.variant = variant
    }

    public func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, isLoading: isLoading, variant: variant)
    }

    private struct Face: View {
        var configuration: Configuration
        var isLoading: Bool
        var variant: Variant
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.metricsScale) private var scale

        var body: some View {
            configuration.label
                .scaledFont(15, weight: .semibold)
                .lineLimit(1)
                .opacity(isLoading ? 0 : 1)
                .overlay {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(variant == .filled ? .white : Theme.accent)
                    }
                }
                .foregroundStyle(foreground)
                .scaledPadding(.horizontal, variant == .plain ? 0 : Theme.Space.md)
                .frame(minHeight: Theme.metric(44, scale))
                .background {
                    switch variant {
                    case .filled: Capsule().fill(Theme.accent)
                    case .tinted: Capsule().fill(Theme.pill)
                    case .plain: EmptyView()
                    }
                }
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.7 : (isEnabled || isLoading ? 1 : 0.45))
                .accessibilityValue(isLoading ? Text("In progress") : Text(verbatim: ""))
        }

        private var foreground: Color {
            variant == .filled ? .white : Theme.accentText
        }
    }
}

public extension View {
    /// `LoadingButtonStyle` plus `.disabled(isLoading)`: the label keeps its width under a spinner and taps
    /// are ignored until the call ends.
    func loadingButton(isLoading: Bool, variant: LoadingButtonStyle.Variant = .tinted) -> some View {
        buttonStyle(LoadingButtonStyle(isLoading: isLoading, variant: variant))
            .disabled(isLoading)
    }
}

#Preview("Loading buttons") {
    VStack(spacing: 14) {
        HStack {
            Button("Accept") {}.loadingButton(isLoading: false)
            Button("Accept") {}.loadingButton(isLoading: true)
        }
        HStack {
            Button("Send Code") {}.loadingButton(isLoading: false, variant: .filled)
            Button("Send Code") {}.loadingButton(isLoading: true, variant: .filled)
        }
        Button("Verify") {}.loadingButton(isLoading: false, variant: .plain).disabled(true)
    }
    .padding()
    .background(Theme.background)
}
