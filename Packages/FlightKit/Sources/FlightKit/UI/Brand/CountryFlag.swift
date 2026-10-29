import SwiftUI

/// A round country flag (circle-flags, MIT) from the Flags asset catalog. An unknown or missing
/// code draws the neutral `flag-xx` disc.
public struct CountryFlag: View {
    var code: String?
    var size: CGFloat
    /// True next to the country's name, where the flag adds nothing for VoiceOver.
    var decorative: Bool

    public init(code: String?, size: CGFloat = 24, decorative: Bool = false) {
        self.code = code; self.size = size; self.decorative = decorative
    }

    /// The bundle holding the Flags asset catalog.
    nonisolated static var bundle: Bundle { .module }

    /// `flag-<iso2 lowercase>` for a code in the bundled country list, else `flag-xx`.
    public nonisolated static func assetName(_ code: String?) -> String {
        guard let code else { return "flag-xx" }
        let key = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ReferenceData.bundled().country(key) != nil ? "flag-" + key : "flag-xx"
    }

    /// The country's name, or "Unknown country" for the fallback disc.
    static func accessibilityName(_ code: String?) -> String {
        code.flatMap { ReferenceData.bundled().country($0)?.name } ?? "Unknown country"
    }

    public var body: some View {
        Image(Self.assetName(code), bundle: .module)
            .resizable()
            .interpolation(.high)
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Theme.separator, lineWidth: 0.5))
            .accessibilityHidden(decorative)
            .accessibilityLabel(Self.accessibilityName(code))
            .accessibilityAddTraits(.isImage)
    }
}
