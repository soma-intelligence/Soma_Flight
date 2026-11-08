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
    /// The aircraft on it; the picker shows one row per plane.
    public var plane: AppIconPlane
    /// The tile's caption inside its plane's row ("Auto", "Navy", "Blueprint").
    public var label: String

    public init(_ assetName: String?, name: String, tagline: String, plane: AppIconPlane = .jet, label: String? = nil) {
        self.assetName = assetName; self.name = name; self.tagline = tagline
        self.plane = plane; self.label = label ?? name
    }

    public var id: String { assetName ?? "AppIcon" }

    /// The picture the picker shows: an ordinary image set ("Preview-supersonic", "Preview-jet" for the primary)
    /// in FlightKit's AppIconPreviews catalog, because an app icon set cannot be loaded as an image.
    public var previewName: String {
        "Preview-" + (assetName.map { String($0.dropFirst("AppIcon-".count)) } ?? AppIcons.primarySlug)
    }
}

/// The picker's rows: the two aircraft the icons carry, then the glass icons.
public enum AppIconPlane: String, CaseIterable, Sendable {
    case jet, supersonic, glass

    public var title: String {
        switch self {
        case .jet: "Jet"
        case .supersonic: "Supersonic"
        case .glass: "Glass"
        }
    }
}

/// The iPhone app's icons: the climbing Jet and the Supersonic, each following the phone's appearance (Auto),
/// on nine fixed grounds (black plane on the light ones, white on the dark ones), and as a blueprint line
/// drawing. The Mac and watch apps keep the primary only (no picker there).
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

    /// The fixed grounds, in the picker's order: slug, caption, and what the tagline says after the plane.
    static let grounds: [(slug: String, label: String, on: String)] = [
        ("white", "White", "in black on pure white"),
        ("paper", "Paper", "in black on warm paper"),
        ("grey", "Grey", "in black on light grey"),
        ("charcoal", "Charcoal", "in white on charcoal"),
        ("black", "Black", "in white on true black"),
        ("navy", "Navy", "in white on midnight navy"),
        ("sky", "Sky", "in white on a clear sky"),
        ("dusk", "Dusk", "in white against a dusk sky"),
        ("blue", "Blue", "in white on the app's blue"),
        ("blueprint", "Blueprint", "drawn in fine lines on blueprint blue"),
    ]

    /// The glass row's other looks, after Contrail: slug, caption and tagline.
    static let glassLooks: [(slug: String, label: String, tagline: String)] = [
        ("sunset", "Sunset", "The contrail in sunset amber and magenta."),
        ("night", "Night", "An icy contrail through midnight glass."),
        ("crystal", "Crystal", "The contrail in clear crystal glass."),
        ("mono", "Mono", "A white contrail in milky glass."),
    ]

    public static let all: [AppIconChoice] = AppIconPlane.allCases.flatMap { plane -> [AppIconChoice] in
        if plane == .glass {
            // Frosted glass with a jet and its contrail glowing inside; light and dark looks, no grounds.
            return [AppIconChoice("AppIcon-glass", name: "Glass Contrail",
                                  tagline: "A contrail glowing through frosted glass.", plane: .glass, label: "Contrail")]
                + glassLooks.map { g in
                    AppIconChoice("AppIcon-glass-\(g.slug)", name: "Glass \(g.label)", tagline: g.tagline,
                                  plane: .glass, label: g.label)
                }
        }
        let auto = plane == .jet
            ? AppIconChoice(nil, name: "Jet", tagline: "Black on white by day, white on charcoal at night.",
                            plane: .jet, label: "Auto")
            : AppIconChoice("AppIcon-supersonic", name: "Supersonic",
                            tagline: "Mach two that follows your appearance.", plane: .supersonic, label: "Auto")
        let subject = plane == .jet ? "Our jet" : "Mach two"
        return [auto] + grounds.map { g in
            AppIconChoice("AppIcon-\(plane.rawValue)-\(g.slug)", name: "\(plane.title) \(g.label)",
                          tagline: "\(subject) \(g.on).", plane: plane, label: g.label)
        }
    }

    /// The icons of one plane, Auto first.
    public static func icons(for plane: AppIconPlane) -> [AppIconChoice] { all.filter { $0.plane == plane } }

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
