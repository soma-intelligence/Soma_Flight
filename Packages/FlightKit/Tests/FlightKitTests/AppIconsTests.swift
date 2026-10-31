import Foundation
import Testing
@testable import FlightKit

/// Settings > App Icon: the list matches the iOS asset catalog both ways, and a change shows at once and
/// goes back when the system refuses it.
@MainActor @Suite struct AppIconsTests {
    static let catalog = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FlightKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FlightKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repository root
        .appending(path: "Apps/iOS/Assets.xcassets")

    @Test func everyListedIconHasItsSetAndEverySetIsListed() throws {
        let sets = try FileManager.default.contentsOfDirectory(atPath: Self.catalog.path())
            .filter { $0.hasSuffix(".appiconset") }
            .map { String($0.dropLast(".appiconset".count)) }
        let listed = AppIcons.all.map { $0.assetName ?? "AppIcon" }
        #expect(Set(sets) == Set(listed))
        #expect(listed.count == Set(listed).count)
        #expect(AppIcons.all.first?.assetName == nil, "the primary comes first")
        #expect(AppIcons.all.first?.name == "Orbit")
        for name in sets {
            let json = try Data(contentsOf: Self.catalog.appending(path: "\(name).appiconset/Contents.json"))
            let images = try #require((try JSONSerialization.jsonObject(with: json) as? [String: Any])?["images"] as? [[String: Any]])
            let files = images.compactMap { $0["filename"] as? String }
            #expect(files.count == 3, "\(name) carries light, dark and tinted")
            for file in files {
                #expect(FileManager.default.fileExists(atPath: Self.catalog.appending(path: "\(name).appiconset/\(file)").path()))
            }
        }
    }

    @Test func taglinesStayShortAndPlain() {
        for icon in AppIcons.all {
            #expect(!icon.name.isEmpty && icon.tagline.count <= 60)
            #expect(!icon.tagline.contains("\u{2014}"))
        }
        #expect(AppIcons.choice(for: "AppIcon-gone").name == "Orbit")
        #expect(AppIcons.choice(for: "AppIcon-ember").name == "Ember")
    }

    final class FakeSetter: AppIconSetting, @unchecked Sendable {
        var currentName: String?
        var fails = false
        var calls: [String?] = []
        var supportsAlternates: Bool { true }
        init(_ name: String?) { currentName = name }
        func setIcon(_ name: String?) async throws {
            calls.append(name)
            if fails { throw CocoaError(.featureUnsupported) }
            currentName = name
        }
    }

    @Test func choosingAnIconAsksTheSystemAndGoesBackOnFailure() async {
        let setter = FakeSetter("AppIcon-sweep")
        let model = AppIconModel(setter: setter)
        #expect(model.current.name == "Sweep")
        await model.select(AppIcons.all[0])
        #expect(setter.calls == [nil])
        #expect(model.current.assetName == nil)
        await model.select(AppIcons.all[0])
        #expect(setter.calls.count == 1, "the icon in use is not set again")
        setter.fails = true
        await model.select(AppIcons.choice(for: "AppIcon-mach"))
        #expect(model.current.assetName == nil)
        #expect(model.failed)
    }
}
