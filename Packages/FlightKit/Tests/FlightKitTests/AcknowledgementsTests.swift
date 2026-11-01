import Foundation
import Testing
@testable import FlightKit

@MainActor
struct AcknowledgementsTests {
    private struct Resolved: Decodable {
        struct Pin: Decodable { let identity: String; let state: State }
        struct State: Decodable { let version: String }
        let pins: [Pin]
    }

    @Test func circleFlagsLicenseLoads() {
        let text = AcknowledgementsView.licenseText("circle-flags")
        #expect(text?.contains("Permission is hereby granted") == true)
        #expect(text?.contains("HatScripts") == true)
    }

    @Test func everyResolvedPackageHasALicenceEntry() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Package.resolved")
        let pins = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: url)).pins
        #expect(pins.count >= 8)
        let blocks = AcknowledgementsView.thirdPartyBlocks
        #expect(blocks.count > 1)
        let applies = blocks.dropFirst().filter { $0.hasPrefix("Applies to:") }
        for pin in pins {
            #expect(applies.contains { $0.prefix(while: { $0 != "\n" }).contains("\(pin.identity) \(pin.state.version)") },
                    "no licence text for \(pin.identity) \(pin.state.version)")
        }
        // The Apache-2.0 packages carry their NOTICE files too.
        for name in ["swift-asn1", "swift-crypto", "swift-http-types"] {
            #expect(applies.contains { $0.prefix(while: { $0 != "\n" }).contains("\(name) ") && $0.prefix(while: { $0 != "\n" }).contains("NOTICE") },
                    "no NOTICE for \(name)")
        }
    }

    @Test func rustCrateLicencesAreShipped() {
        let all = AcknowledgementsView.thirdPartyBlocks.joined(separator: "\n")
        for crate in ["serde ", "uniffi_core ", "chrono-tz ", "anyhow "] {
            #expect(all.contains("Applies to:") && all.contains(crate), "no licence for \(crate)")
        }
        #expect(all.contains("Mozilla Public License Version 2.0"))
        #expect(all.contains("Apache License"))
    }

    /// Every logo kept in assets/logos/commons has a credit line in the app: author, licence, source.
    @Test func everyCommonsLogoHasAnAttributionLine() throws {
        struct Manifest: Decodable {
            struct Logo: Decodable { let license: String; let source_page: String }
            let logos: [String: Logo]
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "assets/logos/commons/manifest.json")
        let logos = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)).logos
        #expect(logos.count >= 100)
        let credits = Dictionary(uniqueKeysWithValues: AcknowledgementsView.logoCredits.map { ($0.icao, $0) })
        #expect(credits.count == logos.count)
        for (icao, logo) in logos {
            let credit = try #require(credits[icao], "no attribution for \(icao)")
            #expect(!credit.author.isEmpty && !credit.name.isEmpty)
            #expect(credit.license == logo.license)
            #expect(credit.source == logo.source_page && credit.source.hasPrefix("https://commons.wikimedia.org/wiki/File:"))
            #expect(credit.attribution.contains("via Wikimedia Commons"))
        }
        let entry = try #require(AcknowledgementsView.entries.first { $0.name == "Airline logos (Wikimedia Commons)" })
        #expect(entry.license.hasPrefix("Public domain"))
    }

    /// Every symbol kept in assets/logos/commons/symbol has a credit line next to its airline's, and every
    /// crop says which Commons file it was cropped from; so does every wordmark, shipped or not.
    @Test func everyCommonsSymbolHasAnAttributionLine() throws {
        struct Entry: Decodable {
            let license: String; let source_page: String; let author: String
            let method: String?; let source_file: String?
        }
        struct Manifest: Decodable { let logos: [String: Entry]; let symbols: [String: Entry] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "assets/logos/commons/manifest.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        #expect(manifest.symbols.count >= 37)
        let credits = Dictionary(uniqueKeysWithValues: AcknowledgementsView.logoCredits.map { ($0.icao, $0) })
        // Wordmarks: a line each (the other test checks the fields).
        for icao in manifest.logos.keys { #expect(credits[icao] != nil, "no wordmark credit for \(icao)") }
        // Symbols: a nested credit with author, licence, source, and the provenance of a crop.
        var crops = 0
        for (icao, entry) in manifest.symbols {
            let credit = try #require(credits[icao], "no credit for \(icao)")
            let symbol = try #require(credit.symbol, "no symbol credit for \(icao)")
            #expect(symbol.author == entry.author && !symbol.author.isEmpty)
            #expect(symbol.license == entry.license)
            #expect(symbol.source == entry.source_page && symbol.source.hasPrefix("https://commons.wikimedia.org/wiki/File:"))
            #expect(symbol.attribution.contains("via Wikimedia Commons"))
            #expect(symbol.creditLine == "Symbol: \(entry.author)")
            if entry.method == "crop" {
                crops += 1
                #expect(symbol.isCrop)
                let line = try #require(symbol.provenanceLine, "no provenance for \(icao)")
                #expect(line.hasPrefix("Cropped from ") && line.count > "Cropped from ".count + 3, "\(icao)")
                #expect(line.contains(try #require(entry.source_file ?? symbol.derived_from)))
            } else {
                #expect(!symbol.isCrop && symbol.provenanceLine == nil)
            }
        }
        #expect(crops >= 31)
        // No credit for a symbol that is not shipped.
        #expect(credits.values.filter { $0.symbol != nil }.count == manifest.symbols.count)
        // The summary row lists the symbols' licences too (KLM crown, CC BY-SA 3.0).
        let licenses = AcknowledgementsView.logoLicenses
        for entry in manifest.symbols.values { #expect(licenses.contains(entry.license)) }
    }

    /// CC BY-SA: every share-alike file, wordmark or symbol, links its licence deed, and a file we changed
    /// (manifest `changes`, or a crop) says it was modified and that the adaptation keeps the licence.
    @Test func everyShareAlikeAssetLinksItsLicenseAndNotesChanges() throws {
        struct Entry: Decodable {
            let license: String; let license_url: String?; let method: String?; let changes: String?
        }
        struct Manifest: Decodable { let logos: [String: Entry]; let symbols: [String: Entry] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "assets/logos/commons/manifest.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        let credits = Dictionary(uniqueKeysWithValues: AcknowledgementsView.logoCredits.map { ($0.icao, $0) })
        typealias Note = AcknowledgementsView.LicenseNote
        var shareAlike = 0, derived = 0
        for (icao, entry) in manifest.logos where Note.isShareAlike(entry.license) {
            shareAlike += 1
            let credit = try #require(credits[icao])
            #expect(Note.deed(credit.license_url) != nil, "no license deed for \(icao)")
            let note = Note.modification(changes: credit.changes, cropped: false, license: credit.license)
            if entry.changes != nil {
                derived += 1
                #expect(note?.hasPrefix("Modified: cropped") == true && note?.contains(entry.license) == true, "\(icao)")
            } else {
                #expect(note == nil, "\(icao) shipped unchanged")
            }
        }
        for (icao, entry) in manifest.symbols where Note.isShareAlike(entry.license) {
            shareAlike += 1
            let symbol = try #require(credits[icao]?.symbol)
            #expect(Note.deed(symbol.license_url) != nil, "no license deed for the \(icao) symbol")
            if entry.changes != nil || entry.method == "crop" {
                derived += 1
                let note = try #require(symbol.modificationNote, "no modification note for the \(icao) symbol")
                #expect(note.hasPrefix("Modified: cropped") && note.contains(entry.license))
            }
        }
        // docs/data-sources.md: the OMA, ROT, SZN, VKG and VOE wordmarks and the KLM crown; one cropped (KLM).
        #expect(shareAlike == 6)
        #expect(derived == 1)
        #expect(credits["KLM"]?.symbol?.modificationNote?.contains("CC BY-SA 3.0") == true)
    }

    @Test func flagLabelsNameTheCountry() {
        #expect(CountryFlag.accessibilityName("fr") == "France")
        #expect(CountryFlag.accessibilityName("ZZ") == "Unknown country")
        #expect(CountryFlag.accessibilityName(nil) == "Unknown country")
        #expect(CountryFlag.assetName(" fr ") == "flag-fr")
    }
}
