import Foundation

/// `#RRGGBB`.
public typealias HexColor = String

/// How an airline paints an aircraft in profile: fuselage top and belly, cheatline stripes, the fin,
/// engines, winglets and the title over the windows. A few airlines are hand-tuned
/// (Resources/Reference/livery_seed.json); every other one is `derived(from:)` its brand colours.
public struct Livery: Codable, Sendable, Hashable {
    public var airline: String
    public var fuselageTop: HexColor
    public var belly: HexColor
    /// Fraction of fuselage height, from the bottom, where the belly colour stops.
    public var bellySplit: Double
    public var cheatline: [Stripe]
    public var tail: TailPaint
    public var engines: HexColor
    public var winglets: HexColor?
    public var title: LiveryTitle?

    public init(airline: String, fuselageTop: HexColor, belly: HexColor, bellySplit: Double,
                cheatline: [Stripe] = [], tail: TailPaint = .solid("#F7F7F8"), engines: HexColor,
                winglets: HexColor? = nil, title: LiveryTitle? = nil) {
        self.airline = airline; self.fuselageTop = fuselageTop; self.belly = belly
        self.bellySplit = bellySplit; self.cheatline = cheatline; self.tail = tail
        self.engines = engines; self.winglets = winglets; self.title = title
    }

    /// White top, light grey belly, grey engines, white fin.
    public static let plain = Livery(airline: "", fuselageTop: "#F7F7F8", belly: "#D5D8DC", bellySplit: 0.3,
                                     tail: .solid("#F7F7F8"), engines: "#C4C8CE")

    /// From the airline's brand colours: white top, light grey belly at 0.3, fin and engines in the
    /// primary colour, one cheatline in the secondary (0.30 to 0.36) when there is one, the airline's name
    /// as the title in the primary colour. A brand colour under 3:1 against white (a pale primary) gives way
    /// to the secondary when that one reads, else to the primary darkened until it does.
    public static func derived(from airline: Airline) -> Livery {
        let primary = Livery.normalized(airline.colorPrimary) ?? "#5A6270"
        let secondary = airline.colorSecondary.flatMap { Livery.normalized($0) }
        let ink = readable(primary, else: secondary)
        return Livery(
            airline: airline.id,
            fuselageTop: "#F7F7F8", belly: "#D5D8DC", bellySplit: 0.3,
            cheatline: secondary.map { [Stripe(color: $0, from: 0.30, to: 0.36, sweep: 0)] } ?? [],
            tail: .solid(ink), engines: ink, winglets: ink,
            title: LiveryTitle(text: airline.name, color: ink, weight: "bold", tracking: 0.02))
    }

    /// The least contrast a title or fin colour keeps against a white fuselage.
    public static let minContrast = 3.0

    /// WCAG contrast of a colour against white; 1 when the text is not a colour.
    public static func contrastOnWhite(_ hex: HexColor) -> Double {
        guard let c = TravelFacts.rgb(hex) else { return 1 }
        return 1.05 / (BrandArt.relativeLuminance(r: c.r, g: c.g, b: c.b) + 0.05)
    }

    /// `primary` when it reads on white (3:1), else `secondary` when that one does, else `primary` mixed
    /// toward black in tenths until it does.
    static func readable(_ primary: HexColor, else secondary: HexColor?) -> HexColor {
        if contrastOnWhite(primary) >= minContrast { return primary }
        if let secondary, contrastOnWhite(secondary) >= minContrast { return secondary }
        guard let c = TravelFacts.rgb(primary) else { return "#5A6270" }
        for step in 1...10 {
            let k = 1 - Double(step) / 10
            let hex = String(format: "#%02X%02X%02X", Int((c.r * k * 255).rounded()), Int((c.g * k * 255).rounded()),
                             Int((c.b * k * 255).rounded()))
            if contrastOnWhite(hex) >= minContrast { return hex }
        }
        return "#000000"
    }

    /// `#RRGGBB` upper case, or nil when the text is not a colour.
    static func normalized(_ hex: String) -> HexColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, UInt32(digits, radix: 16) != nil else { return nil }
        return "#" + digits.uppercased()
    }
}

/// A band along the fuselage, between two fractions of its height from the bottom. `sweep` tilts the
/// aft part of the band up toward the tail, in degrees.
public struct Stripe: Codable, Sendable, Hashable {
    public var color: HexColor
    public var from: Double
    public var to: Double
    public var sweep: Double

    /// The steepest sweep drawn, either way.
    public static let maxSweep = 20.0

    public init(color: HexColor, from: Double, to: Double, sweep: Double = 0) {
        self.color = color; self.from = from; self.to = to
        self.sweep = min(max(sweep, -Self.maxSweep), Self.maxSweep)
    }

    private enum CodingKeys: String, CodingKey { case color, from, to, sweep }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(color: try c.decode(HexColor.self, forKey: .color), from: try c.decode(Double.self, forKey: .from),
                  to: try c.decode(Double.self, forKey: .to), sweep: try c.decodeIfPresent(Double.self, forKey: .sweep) ?? 0)
    }
}

/// The fin's paint. `bands` are hard stripes swept along the fin's leading edge, top first (a flag tail).
/// In JSON: `{"solid": "#..."}`, `{"gradient": [...]}`, `{"split": {"top", "bottom", "at"}}`,
/// `{"bands": [...]}`.
public enum TailPaint: Codable, Sendable, Hashable {
    case solid(HexColor)
    case gradient([HexColor])
    case split(top: HexColor, bottom: HexColor, at: Double)
    case bands([HexColor])

    private enum Key: String, CodingKey { case solid, gradient, split, bands }
    private struct Split: Codable { var top: HexColor; var bottom: HexColor; var at: Double }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard c.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                                                    debugDescription: "A tail paint has exactly one key, found \(c.allKeys.map(\.stringValue))"))
        }
        if let v = try c.decodeIfPresent(HexColor.self, forKey: .solid) { self = .solid(v) }
        else if let v = try c.decodeIfPresent([HexColor].self, forKey: .gradient) { self = .gradient(v) }
        else if let v = try c.decodeIfPresent(Split.self, forKey: .split) { self = .split(top: v.top, bottom: v.bottom, at: v.at) }
        else if let v = try c.decodeIfPresent([HexColor].self, forKey: .bands) { self = .bands(v) }
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Unknown tail paint"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .solid(let v): try c.encode(v, forKey: .solid)
        case .gradient(let v): try c.encode(v, forKey: .gradient)
        case .split(let top, let bottom, let at): try c.encode(Split(top: top, bottom: bottom, at: at), forKey: .split)
        case .bands(let v): try c.encode(v, forKey: .bands)
        }
    }

    /// Every colour the paint uses.
    public var colors: [HexColor] {
        switch self {
        case .solid(let v): [v]
        case .gradient(let v), .bands(let v): v
        case .split(let top, let bottom, _): [top, bottom]
        }
    }
}

/// The airline's name over the windows, set in the app's font (never the airline's wordmark artwork).
public struct LiveryTitle: Codable, Sendable, Hashable {
    public var text: String
    public var color: HexColor
    /// "semibold" | "bold" | "heavy".
    public var weight: String
    /// Letter spacing as a fraction of the type size.
    public var tracking: Double

    /// The weights a title takes.
    public static let weights: Set<String> = ["semibold", "bold", "heavy"]

    public init(text: String, color: HexColor, weight: String, tracking: Double) {
        self.text = text; self.color = color; self.weight = weight; self.tracking = tracking
    }

    private enum CodingKeys: String, CodingKey { case text, color, weight, tracking }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let weight = try c.decode(String.self, forKey: .weight)
        guard Self.weights.contains(weight) else {
            throw DecodingError.dataCorruptedError(forKey: .weight, in: c, debugDescription: "Unknown title weight \(weight)")
        }
        self.init(text: try c.decode(String.self, forKey: .text), color: try c.decode(HexColor.self, forKey: .color),
                  weight: weight, tracking: try c.decode(Double.self, forKey: .tracking))
    }
}

/// The hand-tuned liveries (Resources/Reference/livery_seed.json), by ICAO code.
enum LiverySeed {
    static let all: [String: Livery] = {
        // Resources are processed flat into the bundle; `seedDecodes` proves the file is there and reads.
        guard let url = Bundle.module.url(forResource: "livery_seed", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Livery].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.airline.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
    }()
}
