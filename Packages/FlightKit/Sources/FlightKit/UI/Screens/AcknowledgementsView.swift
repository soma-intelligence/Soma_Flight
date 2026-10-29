import SwiftUI

/// The open data and software Soma Flight builds on, with the full licence text of the one that
/// asks for it (circle-flags, MIT).
public struct AcknowledgementsView: View {
    var scrolls: Bool

    public init() { self.init(scrolls: true) }

    init(scrolls: Bool) { self.scrolls = scrolls }

    struct Entry: Identifiable {
        var name: String
        var detail: String
        var license: String
        var id: String { name }
    }

    static let entries = [
        Entry(name: "circle-flags", detail: "Round country flags by HatScripts", license: "MIT"),
        Entry(name: "OurAirports", detail: "Airport and runway reference data", license: "Public domain"),
        Entry(name: "Wikidata", detail: "Country and aircraft reference data", license: "CC0"),
        Entry(name: "Natural Earth", detail: "Country borders and map data", license: "Public domain"),
        Entry(name: "supabase-swift", detail: "Sign in and sync", license: "MIT"),
    ]

    /// The circle-flags licence as shipped in the app.
    static var circleFlagsLicense: String {
        guard let url = Bundle.module.url(forResource: "circle-flags", withExtension: "txt", subdirectory: "Licenses")
                ?? Bundle.module.url(forResource: "circle-flags", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "MIT License" }
        return text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("Acknowledgements")
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.top, 22)
                .scaledPadding(.bottom, 16)
            ScreenScroll(scrolls: scrolls) { content }
        }
        .background(Theme.background)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            CapsHeader("Built with")
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.bottom, 8)
            Hairline().scaledPadding(.horizontal, 16)
            ForEach(Array(Self.entries.enumerated()), id: \.element.id) { i, entry in
                row(entry, last: i == Self.entries.count - 1)
            }
            Hairline().scaledPadding(.horizontal, 16)
            CapsHeader("circle-flags licence")
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 34)
                .scaledPadding(.bottom, 8)
            Hairline().scaledPadding(.horizontal, 16)
            Text(Self.circleFlagsLicense)
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.vertical, 14)
            Hairline().scaledPadding(.horizontal, 16)
        }
        .scaledPadding(.bottom, 32)
    }

    private func row(_ entry: Entry, last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).scaledFont(17).foregroundStyle(Theme.primary)
                    Text(entry.detail).scaledFont(13).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(entry.license).scaledFont(15).foregroundStyle(Theme.secondary)
            }
            .scaledPadding(.horizontal, 16)
            .frame(minHeight: 60)
            .accessibilityElement(children: .combine)
            if !last { Hairline().scaledPadding(.horizontal, 16) }
        }
    }
}

#if DEBUG
#Preview("Acknowledgements, dark") { AcknowledgementsView().preferredColorScheme(.dark) }
#Preview("Acknowledgements, light") { AcknowledgementsView().preferredColorScheme(.light) }
#endif
