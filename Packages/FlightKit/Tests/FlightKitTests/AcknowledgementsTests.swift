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

    @Test func flagLabelsNameTheCountry() {
        #expect(CountryFlag.accessibilityName("fr") == "France")
        #expect(CountryFlag.accessibilityName("ZZ") == "Unknown country")
        #expect(CountryFlag.accessibilityName(nil) == "Unknown country")
        #expect(CountryFlag.assetName(" fr ") == "flag-fr")
    }
}
