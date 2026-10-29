import SwiftUI

/// A round country flag (circle-flags, MIT) from the Flags asset catalog. An unknown or missing
/// code draws the neutral `flag-xx` disc.
public struct CountryFlag: View {
    var code: String?
    var size: CGFloat

    public init(code: String?, size: CGFloat = 24) {
        self.code = code; self.size = size
    }

    /// The bundle holding the Flags asset catalog.
    nonisolated static var bundle: Bundle { .module }

    /// `flag-<iso2 lowercase>` for a code in the bundled country list, else `flag-xx`.
    public nonisolated static func assetName(_ code: String?) -> String {
        guard let code, ReferenceData.bundled().country(code) != nil else { return "flag-xx" }
        return "flag-" + code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var body: some View {
        Image(Self.assetName(code), bundle: .module)
            .resizable()
            .interpolation(.high)
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Theme.separator, lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
