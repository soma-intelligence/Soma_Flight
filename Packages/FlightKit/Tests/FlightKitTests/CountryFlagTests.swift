#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import FlightKit

struct CountryFlagTests {
    private struct Entry: Decodable { let iso2: String }

    @Test func everyCountryHasAFlag() throws {
        let bundle = CountryFlag.bundle
        let url = try #require(bundle.url(forResource: "countries", withExtension: "json", subdirectory: "Reference")
            ?? bundle.url(forResource: "countries", withExtension: "json"))
        let codes = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url)).map(\.iso2)
        #expect(codes.count == 250)
        for code in codes {
            let name = CountryFlag.assetName(code)
            #expect(name == "flag-" + code.lowercased())
            #expect(bundle.image(forResource: NSImage.Name(name)) != nil, "no flag for \(code)")
        }
        #expect(bundle.image(forResource: NSImage.Name("flag-xx")) != nil)
    }

    @Test func unknownCodeUsesFallback() {
        #expect(CountryFlag.assetName("ZZ") == "flag-xx")
        #expect(CountryFlag.assetName(nil) == "flag-xx")
        #expect(CountryFlag.assetName("") == "flag-xx")
        #expect(CountryFlag.assetName("USA") == "flag-xx")
    }

    @Test func assetNameLowercases() {
        #expect(CountryFlag.assetName("US") == "flag-us")
        #expect(CountryFlag.assetName("xk") == "flag-xk")
    }
}
#endif
