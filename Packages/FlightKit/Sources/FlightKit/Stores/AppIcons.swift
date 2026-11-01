import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// One icon Settings > App Icon offers: the app icon set's name in the iOS app's asset catalog (nil for
/// the primary icon), and what the picker says about it.
public struct AppIconChoice: Identifiable, Hashable, Sendable {
    /// The alternate icon's app icon set ("AppIcon-supersonic"); nil for the primary `AppIcon`.
    public var assetName: String?
    public var name: String
    public var tagline: String

    public init(_ assetName: String?, name: String, tagline: String) {
        self.assetName = assetName; self.name = name; self.tagline = tagline
    }

    public var id: String { assetName ?? "AppIcon" }

    /// The picture the picker shows: an ordinary image set ("Preview-supersonic", "Preview-jet" for the primary)
    /// in FlightKit's AppIconPreviews catalog, because an app icon set cannot be loaded as an image.
    public var previewName: String {
        "Preview-" + (assetName.map { String($0.dropFirst("AppIcon-".count)) } ?? AppIcons.primarySlug)
    }
}

/// The iPhone app's icons: the climbing Jet and the Supersonic, each in black on white, white on charcoal, or
/// following the phone's appearance. The Mac app keeps its one icon (no picker on macOS).
///
/// All of it is built by `assets/app-icon/family.py` from the raws in `assets/app-icon/raw`:
/// - `Apps/iOS/Assets.xcassets/AppIcon.appiconset` (the primary, the set `project.yml` names) and one
///   `AppIcon-<slug>.appiconset` per alternate, each with a light, dark and tinted 1024 px image. The iOS target
///   builds every app icon set in the catalog as an alternate icon (`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS`
///   in `project.yml`).
/// - FlightKit's `Resources/AppIconPreviews.xcassets`: one `Preview-<slug>` per icon, with its light and dark
///   look, which the picker draws (`AppIconChoice.previewName`), and `BrandMark`, the Jet the sign-in screen shows.
/// - The watch and Mac `AppIcon` sets (white jet on charcoal).
///
/// To add an icon, add it to `family.py`, run it, then add one line to `all` below.
/// `AppIconsTests` checks that every line has its set and its preview, and every set has its line.
public enum AppIcons {
    /// The primary icon's preview slug: `Preview-jet`.
    static let primarySlug = "jet"

    public static let all: [AppIconChoice] = [
        AppIconChoice(nil, name: "Jet", tagline: "Black on white by day, white on charcoal at night."),
        AppIconChoice("AppIcon-jet-light", name: "Jet Light", tagline: "Our jet in black on white, all the time."),
        AppIconChoice("AppIcon-jet-dark", name: "Jet Dark", tagline: "Our jet in white on charcoal, all the time."),
        AppIconChoice("AppIcon-supersonic", name: "Supersonic", tagline: "A delta-wing airliner that follows your appearance."),
        AppIconChoice("AppIcon-supersonic-light", name: "Supersonic Light", tagline: "Mach two in black on white."),
        AppIconChoice("AppIcon-supersonic-dark", name: "Supersonic Dark", tagline: "Mach two in white on charcoal."),
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
