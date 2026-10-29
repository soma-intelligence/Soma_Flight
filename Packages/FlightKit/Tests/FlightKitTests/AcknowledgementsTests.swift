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

    @Test func flagLabelsNameTheCountry() {
        #expect(CountryFlag.accessibilityName("fr") == "France")
        #expect(CountryFlag.accessibilityName("ZZ") == "Unknown country")
        #expect(CountryFlag.accessibilityName(nil) == "Unknown country")
        #expect(CountryFlag.assetName(" fr ") == "flag-fr")
    }
}
