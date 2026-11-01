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
        let previews = try FileManager.default.contentsOfDirectory(atPath: Self.catalog.path())
            .filter { $0.hasSuffix(".imageset") }
            .map { String($0.dropLast(".imageset".count)) }
        #expect(Set(previews) == Set(AppIcons.all.map(\.previewName)), "one preview image set per listed icon, no strays")
        for choice in AppIcons.all {
            let dir = Self.catalog.appending(path: "\(choice.previewName).imageset")
            let json = try Data(contentsOf: dir.appending(path: "Contents.json"))
            let images = try #require((try JSONSerialization.jsonObject(with: json) as? [String: Any])?["images"] as? [[String: Any]])
            let file = try #require(images.first?["filename"] as? String)
            #expect(images.count == 1)
            #expect(FileManager.default.fileExists(atPath: dir.appending(path: file).path()), "\(choice.previewName) has its picture")
        }
        #expect(listed.count == Set(listed).count)
        #expect(AppIcons.all.first?.assetName == nil, "the primary comes first")
        #expect(AppIcons.all.first?.name == "Jet")
        #expect(AppIcons.choice(for: "AppIcon-orbit").name == "Orbit", "the old globe stays as an alternate")
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

    @Test func previewNamesFollowTheSetNames() {
        #expect(AppIcons.all[0].previewName == "Preview-jet")
        #expect(AppIcons.choice(for: "AppIcon-orbit").previewName == "Preview-orbit")
        #expect(AppIcons.choice(for: "AppIcon-ember").previewName == "Preview-ember")
        #expect(AppIcons.choice(for: "AppIcon-lastcall").previewName == "Preview-lastcall")
    }

    @Test func taglinesStayShortAndPlain() {
        for icon in AppIcons.all {
            #expect(!icon.name.isEmpty && icon.tagline.count <= 60)
            #expect(!icon.tagline.contains("\u{2014}"))
        }
        #expect(AppIcons.choice(for: "AppIcon-gone").name == "Jet")
        #expect(AppIcons.choice(for: "AppIcon-orbit-jet").name == "Jet", "the retired jet alternate falls back to the primary")
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
        #expect(model.lastError != nil, "the system's error is kept, not dropped")
        setter.fails = false
        await model.select(AppIcons.choice(for: "AppIcon-mach"))
        #expect(!model.failed && model.current.assetName == "AppIcon-mach")
        #expect(setter.currentName == "AppIcon-mach")
    }

    @Test func theCurrentIconFollowsAChange() async {
        let setter = FakeSetter(nil)
        let model = AppIconModel(setter: setter)
        #expect(model.current.name == "Jet")
        await model.select(AppIcons.choice(for: "AppIcon-sweep"))
        #expect(model.current.name == "Sweep", "Settings reads this for its row's subtitle")
    }
}
