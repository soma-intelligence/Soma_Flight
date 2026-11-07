import SwiftUI

/// The open data and software Soma Flight builds on, with the full licence text of the one that
/// asks for it (circle-flags, MIT) and a credit line for every airline wordmark and symbol taken from
/// Wikimedia Commons, with the source file a symbol was cropped from.
public struct AcknowledgementsView: View {
    var scrolls: Bool
    /// Shows a Done button in the header row; nil leaves it out (a pushed screen has its own back button).
    var onDone: (() -> Void)?
    /// Snapshots draw only the first licence texts.
    var textLimit: Int?

    public init(onDone: (() -> Void)? = nil) { self.init(scrolls: true, onDone: onDone) }

    init(scrolls: Bool, onDone: (() -> Void)? = nil, textLimit: Int? = nil) {
        self.scrolls = scrolls; self.onDone = onDone; self.textLimit = textLimit
    }

    struct Entry: Identifiable {
        var name: String
        var detail: String
        var license: String
        var id: String { name }
    }

    /// One airline logo from Wikimedia Commons, as written by Scripts/logos/fetch_commons.py into
    /// Resources/Licenses/airline-logos.json (from assets/logos/commons/manifest.json).
    struct LogoCredit: Decodable, Identifiable, Equatable {
        var icao: String
        var name: String
        var author: String
        var license: String
        var license_url: String?
        var source: String
        var attribution: String
        /// What we changed in the file, when we changed it (manifest `changes`).
        var changes: String?
        /// The airline's compact symbol, when it has one: a separate Commons file or a crop of the wordmark's.
        var symbol: SymbolCredit?
        var id: String { icao }
    }

    /// The credit of an airline's symbol. `method` is "crop" when the symbol was cut out of a Commons
    /// logo, `derived_from` then names that source file.
    struct SymbolCredit: Decodable, Equatable {
        var author: String
        var license: String
        var license_url: String?
        var source: String
        var attribution: String
        var method: String?
        var derived_from: String?
        /// What we changed in the file, when we changed it (manifest `changes`).
        var changes: String?

        var isCrop: Bool { method == "crop" }

        /// "Symbol: author".
        var creditLine: String { "Symbol: \(author)" }

        /// "Modified: cropped" for a file we changed; a share-alike one also says its licence carries over.
        var modificationNote: String? { LicenseNote.modification(changes: changes, cropped: isCrop, license: license) }

        /// "Cropped from <source file>" for a crop; nil for a symbol that is a Commons file of its own.
        var provenanceLine: String? {
            guard isCrop else { return nil }
            return "Cropped from \(derived_from ?? "the wordmark's file")"
        }
    }

    /// Licence wording shared by the wordmark and symbol credits.
    enum LicenseNote {
        static func isShareAlike(_ license: String) -> Bool { license.contains("BY-SA") }

        /// The licence deed, for a Creative Commons licence.
        static func deed(_ url: String?) -> URL? {
            guard let url, url.hasPrefix("https://creativecommons.org/") else { return nil }
            return URL(string: url)
        }

        /// "Modified: cropped (what changed)", plus the licence the adaptation is offered under when the
        /// source is share-alike; nil for a file shipped as it is.
        static func modification(changes: String?, cropped: Bool, license: String) -> String? {
            guard changes != nil || cropped else { return nil }
            var note = "Modified: cropped"
            if let changes { note += " (\(changes))" }
            if isShareAlike(license) { note += ". This version is also under \(license)." }
            return note
        }
    }

    static let logoCredits: [LogoCredit] = {
        guard let url = Bundle.module.url(forResource: "airline-logos", withExtension: "json", subdirectory: "Licenses")
                ?? Bundle.module.url(forResource: "airline-logos", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([LogoCredit].self, from: data)) ?? []
    }()

    /// The licences the logos are under, public domain first (for the summary row).
    static var logoLicenses: String {
        let all = Set(logoCredits.map(\.license) + logoCredits.compactMap { $0.symbol?.license })
        return all.sorted { ($0 == "Public domain" ? 0 : 1, $0) < ($1 == "Public domain" ? 0 : 1, $1) }
            .joined(separator: ", ")
    }

    static let entries = [
        Entry(name: "circle-flags", detail: "Round country flags by HatScripts", license: "MIT"),
        Entry(name: "Airline logos (Wikimedia Commons)",
              detail: "Wordmarks and symbols, credited one by one below. Logos are the airlines' trademarks.", license: logoLicenses),
        Entry(name: "OurAirports", detail: "Airport and runway reference data", license: "Public domain"),
        Entry(name: "Wikidata", detail: "Country and aircraft reference data", license: "CC0"),
        Entry(name: "Natural Earth", detail: "Country borders and map data", license: "Public domain"),
        Entry(name: "Swift packages", detail: "supabase-swift and the packages it uses", license: "MIT, Apache-2.0"),
        Entry(name: "Rust crates", detail: "The flight engine's dependencies", license: "MIT, Apache-2.0, MPL-2.0"),
    ]

    /// Everything the app is linked with, generated by Scripts/licenses/build_third_party.py: the first
    /// block lists the packages, each next one is a licence text with the packages it applies to.
    static var thirdPartyBlocks: [String] {
        guard let text = licenseText("third-party") else { return [] }
        return text.components(separatedBy: "\n%%%%%%%%\n")
    }

    /// The circle-flags licence as shipped in the app.
    static var circleFlagsLicense: String { licenseText("circle-flags") ?? "" }

    static func licenseText(_ name: String) -> String? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Licenses")
                ?? Bundle.module.url(forResource: name, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onDone {
                HStack {
                    Spacer()
                    Button("Done", action: onDone)
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.top, 8)
            }
            Text("Acknowledgements")
                .scaledFont(32, weight: .bold, relativeTo: .largeTitle)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.top, onDone == nil ? 22 : 0)
                .scaledPadding(.bottom, 16)
            ScreenScroll(scrolls: scrolls) { content }
        }
        .background(Theme.background)
    }

    private var content: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            CapsHeader("Built with")
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.bottom, 8)
            Hairline().scaledPadding(.horizontal, 16)
            ForEach(Array(Self.entries.enumerated()), id: \.element.id) { i, entry in
                row(entry, last: i == Self.entries.count - 1)
            }
            Hairline().scaledPadding(.horizontal, 16)
            CapsHeader("circle-flags license")
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 34)
                .scaledPadding(.bottom, 8)
            Hairline().scaledPadding(.horizontal, 16)
            Text(ui: Self.circleFlagsLicense)
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.vertical, 14)
            Hairline().scaledPadding(.horizontal, 16)
            CapsHeader("Airline logos (Wikimedia Commons)")
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 34)
                .scaledPadding(.bottom, 8)
            Hairline().scaledPadding(.horizontal, 16)
            let credits = Array(Self.logoCredits.prefix(textLimit ?? .max))
            ForEach(credits) { credit in
                logoCredit(credit)
                Hairline().scaledPadding(.horizontal, 16)
            }
            CapsHeader("Third-party licenses")
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 34)
                .scaledPadding(.bottom, 8)
            Hairline().scaledPadding(.horizontal, 16)
            let blocks = Array(Self.thirdPartyBlocks.prefix(textLimit ?? .max))
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                Text(ui: block)
                    .scaledFont(12)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.vertical, 14)
                Hairline().scaledPadding(.horizontal, 16)
            }
        }
        .scaledPadding(.bottom, 32)
    }

    private func logoCredit(_ credit: LogoCredit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(credit.name) (\(credit.icao))").scaledFont(15).foregroundStyle(Theme.primary)
            Text(ui: credit.author).scaledFont(13).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            license(credit.license, url: credit.license_url)
            if let note = LicenseNote.modification(changes: credit.changes, cropped: false, license: credit.license) {
                Text(ui: note).scaledFont(13).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = URL(string: credit.source) {
                Link(destination: url) {
                    Text("Source on Wikimedia Commons").scaledFont(13).foregroundStyle(Theme.accent)
                }
                .accessibilityHint(credit.source)
            }
            if let symbol = credit.symbol {
                Text(ui: symbol.creditLine).scaledFont(13).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaledPadding(.top, 4)
                license(symbol.license, url: symbol.license_url)
                if let line = symbol.provenanceLine {
                    Text(ui: line).scaledFont(13).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = symbol.modificationNote {
                    Text(ui: note).scaledFont(13).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !symbol.isCrop, let url = URL(string: symbol.source) {
                    Link(destination: url) {
                        Text("Symbol source on Wikimedia Commons").scaledFont(13).foregroundStyle(Theme.accent)
                    }
                    .accessibilityHint(symbol.source)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.vertical, 10)
    }

    /// The licence name, a link to its deed for a Creative Commons licence.
    @ViewBuilder private func license(_ name: String, url: String?) -> some View {
        if let deed = LicenseNote.deed(url) {
            Link(destination: deed) {
                Text(ui: name).scaledFont(13).foregroundStyle(Theme.accent)
            }
            .accessibilityHint("Opens the \(name) license deed")
        } else {
            Text(ui: name).scaledFont(13).foregroundStyle(Theme.secondary)
        }
    }

    private func row(_ entry: Entry, last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ui: entry.name).scaledFont(17).foregroundStyle(Theme.primary)
                    Text(ui: entry.detail).scaledFont(13).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(ui: entry.license).scaledFont(15).foregroundStyle(Theme.secondary)
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
