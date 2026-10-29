import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Design tokens. Dark is the primary look (sheets over a satellite globe); light variants keep
/// the same hues with enough contrast on white.
public enum Theme {
    // MARK: Surfaces
    /// Sheet and page background.
    public static let background = Color(light: 0xF2F2F7, dark: 0x18181A)
    /// Inset cards (weather category card, flight card).
    public static let card = Color(light: 0xFFFFFF, dark: 0x202023)
    /// Every other board row.
    public static let rowAlt = Color(light: 0xEBEBF0, dark: 0x202024)
    /// Major issues card fill and its rim.
    public static let issues = Color(light: 0xFBE4E6, dark: 0x3E1620)
    public static let issuesRim = Color(light: 0xF0B9BE, dark: 0x5A3841)
    /// Chart grid lines and hairlines.
    public static let grid = Color(light: 0xD8D8DD, dark: 0x373738)
    public static let separator = Color(light: 0xC6C6C8, dark: 0x2E2E31)
    /// Inactive ticks on wind bars.
    public static let tickOff = Color(light: 0xD1D1D6, dark: 0x37373B)

    // MARK: Text
    public static let primary = Color(light: 0x000000, dark: 0xFFFFFF)
    public static let secondary = Color(light: 0x6C6C72, dark: 0x96969D)
    public static let accent = Color(light: 0x007AFF, dark: 0x0A84FF)

    // MARK: Delay levels (board dots, map routes, per-hour chart)
    public static let onTime = Color(light: 0x0E9F5B, dark: 0x12B76A)
    public static let late = Color(light: 0xE59A00, dark: 0xFDB022)
    public static let veryLate = Color(light: 0xE5372C, dark: 0xFF453A)
    public static let canceled = Color(light: 0x8E8E93, dark: 0xFFFFFF)
    public static let diverted = Color(light: 0x9C3DD6, dark: 0xBF5AF2)

    // MARK: Performance split and delay trend (softer, as in the airport sheet)
    public static let splitGreen = Color(light: 0x34A15A, dark: 0x54B471)
    public static let splitRed = Color(light: 0xD8412F, dark: 0xEB5545)
    public static let trendAmber = Color(light: 0xE0A030, dark: 0xF2B347)
    public static let trendFuture = Color(light: 0xF2C5BF, dark: 0x562826)

    // MARK: Flight categories (weather scale bars)
    public static let lifr = Color(light: 0xB82E7C, dark: 0xCB398D)
    public static let ifr = Color(light: 0xC9432F, dark: 0xDD5242)
    public static let mvfr = Color(light: 0x2F74E0, dark: 0x4C8EF2)
    public static let vfr = Color(light: 0x34A15A, dark: 0x54B471)
    /// Active ticks on wind bars.
    public static let wind = Color(light: 0x2F86E0, dark: 0x5AAEF0)

    // MARK: Type
    /// Text styles whose default iOS size matches the reference, so they follow Dynamic Type.
    /// macOS text styles are smaller (body is 13 pt) and macOS has no Dynamic Type, so the Mac
    /// gets the same point sizes as fixed system fonts.
    public enum Font {
        /// 20 pt bold.
        public static let sheetTitle = pick(SwiftUI.Font.title3.bold(), 20, .bold)
        /// 17 pt semibold.
        public static let sectionTitle = pick(.headline, 17, .semibold)
        /// 13 pt.
        public static let sectionSubtitle = pick(.footnote, 13)
        /// 15 pt.
        public static let label = pick(.subheadline, 15)
        /// 22 pt semibold.
        public static let bigNumber = pick(SwiftUI.Font.title2.weight(.semibold), 22, .semibold)
        /// 17 pt.
        public static let body = pick(.body, 17)
        /// 12 pt.
        public static let axis = pick(.caption, 12)
        /// 11 pt medium, monospaced.
        public static let chip = pick(SwiftUI.Font.caption2.weight(.medium).monospaced(), 11, .medium, .monospaced)

        private static func pick(_ style: SwiftUI.Font, _ size: CGFloat, _ weight: SwiftUI.Font.Weight = .regular,
                                 _ design: SwiftUI.Font.Design = .default) -> SwiftUI.Font {
            #if os(macOS)
            .system(size: size, weight: weight, design: design)
            #else
            style
            #endif
        }
    }

    // MARK: Metrics
    public static let gutter: CGFloat = 20
    public static let cardRadius: CGFloat = 14
    public static let sheetRadius: CGFloat = 38
}

public extension Color {
    /// A colour that follows the appearance: `dark` in dark mode, `light` otherwise. Hex is 0xRRGGBB.
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// System font at a reference point size that still follows Dynamic Type: the size is a
/// `@ScaledMetric` tied to the nearest text style, so the default (Large) setting renders the
/// exact reference size. Use it for the custom sizes the screenshots call for.
struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    var weight: SwiftUI.Font.Weight
    var design: SwiftUI.Font.Design

    init(size: CGFloat, weight: SwiftUI.Font.Weight, design: SwiftUI.Font.Design, relativeTo style: SwiftUI.Font.TextStyle?) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style ?? Self.style(for: size))
        self.weight = weight; self.design = design
    }

    /// The text style whose default size is closest, so scaling follows Apple's curve for it.
    static func style(for size: CGFloat) -> SwiftUI.Font.TextStyle {
        switch size {
        case ..<11.5: .caption2
        case ..<12.5: .caption
        case ..<14: .footnote
        case ..<15.5: .subheadline
        case ..<16.5: .callout
        case ..<18.5: .body
        case ..<21: .title3
        case ..<25: .title2
        case ..<30: .title
        default: .largeTitle
        }
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// `.font(.system(size:weight:design:))` that scales with Dynamic Type.
    func scaledFont(_ size: CGFloat, weight: SwiftUI.Font.Weight = .regular, design: SwiftUI.Font.Design = .default,
                    relativeTo style: SwiftUI.Font.TextStyle? = nil) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design, relativeTo: style))
    }
}

/// Section heading used across airport and flight sheets: semibold title, grey subtitle.
public struct SectionHeader: View {
    var title: String
    var subtitle: String?
    var large: Bool

    public init(_ title: String, subtitle: String? = nil, large: Bool = false) {
        self.title = title; self.subtitle = subtitle; self.large = large
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(large ? Theme.Font.sheetTitle : Theme.Font.sectionTitle)
                .foregroundStyle(Theme.primary)
            if let subtitle {
                Group {
                    if large { Text(subtitle).scaledFont(14) } else { Text(subtitle).font(Theme.Font.sectionSubtitle) }
                }
                .foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
