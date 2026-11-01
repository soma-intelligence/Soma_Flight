import SwiftUI

/// A large, soft illustration for an empty screen: our glossy white jet on its own, nothing drawn around it.
/// The pictures come from assets/empty-states (Azure gpt-image-2.5, the v4 icon jet as the style reference).
/// Decorative: VoiceOver skips it, the text under it speaks. The jet floats gently, and stays still with
/// Reduce Motion.
struct EmptyStateIllustration: View {
    /// Which picture, so each empty screen gets its own.
    enum Variant {
        /// The jet in pure side profile, level flight (Passport).
        case stamp
        /// The jet seen three-quarters from the front, climbing (My Flights).
        case climb

        var asset: String {
            switch self {
            case .stamp: "empty-jet-profile"
            case .climb: "empty-jet-climb"
            }
        }
    }

    var variant: Variant = .stamp
    /// The width of the picture in points; accessibility text sizes take it down to 72% to leave room for the words.
    var size: CGFloat = 300

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme
    @State private var floating = false

    private var width: CGFloat { typeSize.isAccessibilitySize ? size * 0.72 : size }

    var body: some View {
        Image(variant.asset, bundle: .module)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: width)
            // A soft shadow under the jet: it lifts the white paint off the light sheet, and barely shows in dark.
            .shadow(color: Color.black.opacity(scheme == .dark ? 0.5 : 0.14), radius: 14, y: 12)
            .offset(y: floating ? -4 : 4)
            .scaledPadding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { floating = true }
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { withAnimation(.easeOut(duration: 0.3)) { floating = false } }
            }
    }
}

#if DEBUG
#Preview("Profile") {
    EmptyStateIllustration().padding().background(Theme.background).preferredColorScheme(.dark)
}
#Preview("Climb, light") {
    EmptyStateIllustration(variant: .climb, size: 240).padding().background(Theme.background).preferredColorScheme(.light)
}
#endif
