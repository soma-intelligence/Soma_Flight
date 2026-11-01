import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// One icon Settings > App Icon offers: the app icon set's name in the iOS app's asset catalog (nil for
/// the primary icon), and what the picker says about it.
public struct AppIconChoice: Identifiable, Hashable, Sendable {
    /// The alternate icon's app icon set ("AppIcon-ember"); nil for the primary `AppIcon`.
    public var assetName: String?
    public var name: String
    public var tagline: String

    public init(_ assetName: String?, name: String, tagline: String) {
        self.assetName = assetName; self.name = name; self.tagline = tagline
    }

    public var id: String { assetName ?? "AppIcon" }

    /// The picture the picker shows: an ordinary image set ("Preview-ember", "Preview-orbit") in the iOS
    /// app's asset catalog, because an app icon set cannot be loaded as an image.
    public var previewName: String {
        "Preview-" + (assetName.map { String($0.dropFirst("AppIcon-".count)) } ?? "orbit")
    }
}

/// The iPhone app's icons. The Mac app keeps its one icon (no picker on macOS).
///
/// To add an icon:
/// 1. Drop an app icon set named `AppIcon-<slug>.appiconset` into `Apps/iOS/Assets.xcassets`, with a
///    1024 px light, dark and tinted image (copy the `Contents.json` of an existing set). The iOS target
///    builds every app icon set in the catalog as an alternate icon
///    (`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS` in `project.yml`), so nothing else changes there.
/// 2. Add one `Preview-<slug>.imageset` beside it: the light image downscaled to about 180 px, which is
///    what the picker draws (`AppIconChoice.previewName`).
/// 3. Add one line to `all` below with its set name, name and tagline.
///
/// `AppIconsTests` checks that every line has its set and its preview, and every set has its line.
public enum AppIcons {
    public static let all: [AppIconChoice] = [
        AppIconChoice(nil, name: "Orbit", tagline: "A flight path circling the globe. The original."),
        AppIconChoice("AppIcon-ember", name: "Ember", tagline: "A white jet over a warm coral glow."),
        AppIconChoice("AppIcon-redeye", name: "Red Eye", tagline: "Red to port, green to starboard, wheels up at midnight."),
        AppIconChoice("AppIcon-sweep", name: "Sweep", tagline: "One coral sweep, every blip a flight."),
        AppIconChoice("AppIcon-lastcall", name: "Last Call", tagline: "The board flips, the gate closes, you're on."),
        AppIconChoice("AppIcon-spectrum", name: "Spectrum", tagline: "Fly proud and leave a rainbow behind."),
        AppIconChoice("AppIcon-mach", name: "Mach Two", tagline: "Afterburners on, breakfast in another time zone."),
        AppIconChoice("AppIcon-nightside", name: "Night Side", tagline: "Cities glowing below at cruising altitude."),
        AppIconChoice("AppIcon-orbit-jet", name: "Jet", tagline: "A long-range business jet on charcoal. Nothing else to say."),
    ]

    /// The choice for an alternate icon name as the system reports it; the primary for nil or a name no
    /// longer listed.
    public static func choice(for assetName: String?) -> AppIconChoice {
        all.first { $0.assetName == assetName } ?? all[0]
    }
}

/// Where the app icon is read and changed: `UIApplication` on the phone, a fake in tests.
public protocol AppIconSetting: Sendable {
    /// The alternate icon in use; nil for the primary.
    @MainActor var currentName: String? { get }
    @MainActor var supportsAlternates: Bool { get }
    @MainActor func setIcon(_ name: String?) async throws
}

/// Settings > App Icon's state: the icon in use, and a change that shows at once and goes back if the
/// system refuses it.
@MainActor @Observable
public final class AppIconModel {
    public private(set) var current: AppIconChoice
    /// True while the system changes the icon (it shows its own alert when done).
    public private(set) var isChanging = false
    /// The error of the last change the system refused; cleared by the next one.
    public private(set) var lastError: (any Error)?
    /// True when the last change failed.
    public var failed: Bool { lastError != nil }
    @ObservationIgnored private let setter: any AppIconSetting

    public init(setter: any AppIconSetting) {
        self.setter = setter
        current = AppIcons.choice(for: setter.currentName)
    }

    public var isAvailable: Bool { setter.supportsAlternates }

    public func select(_ choice: AppIconChoice) async {
        guard choice != current, !isChanging else { return }
        let before = current
        current = choice
        lastError = nil
        isChanging = true
        defer { isChanging = false }
        do {
            try await setter.setIcon(choice.assetName)
        } catch {
            current = before
            lastError = error
            Logger(subsystem: "me.somalabs.flight", category: "appicon")
                .error("Changing the app icon failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#if canImport(UIKit) && !os(watchOS)
/// The app's own icon through `UIApplication`.
public struct SystemAppIconSetting: AppIconSetting {
    public init() {}
    @MainActor public var currentName: String? { UIApplication.shared.alternateIconName }
    @MainActor public var supportsAlternates: Bool { UIApplication.shared.supportsAlternateIcons }
    @MainActor public func setIcon(_ name: String?) async throws { try await UIApplication.shared.setAlternateIconName(name) }
}
#endif
