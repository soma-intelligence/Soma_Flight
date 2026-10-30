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
    /// as the title in the primary colour.
    public static func derived(from airline: Airline) -> Livery {
        let primary = Livery.normalized(airline.colorPrimary) ?? "#5A6270"
        let secondary = airline.colorSecondary.flatMap { Livery.normalized($0) }
        return Livery(
            airline: airline.id,
            fuselageTop: "#F7F7F8", belly: "#D5D8DC", bellySplit: 0.3,
            cheatline: secondary.map { [Stripe(color: $0, from: 0.30, to: 0.36, sweep: 0)] } ?? [],
            tail: .solid(primary), engines: primary, winglets: primary,
            title: LiveryTitle(text: airline.name, color: primary, weight: "bold", tracking: 0.02))
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

    public init(color: HexColor, from: Double, to: Double, sweep: Double = 0) {
        self.color = color; self.from = from; self.to = to; self.sweep = sweep
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

    public init(text: String, color: HexColor, weight: String, tracking: Double) {
        self.text = text; self.color = color; self.weight = weight; self.tracking = tracking
    }
}

/// The hand-tuned liveries (Resources/Reference/livery_seed.json), by ICAO code.
enum LiverySeed {
    static let all: [String: Livery] = {
        guard let url = Bundle.module.url(forResource: "livery_seed", withExtension: "json", subdirectory: "Reference")
                ?? Bundle.module.url(forResource: "livery_seed", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        do {
            let list = try JSONDecoder().decode([Livery].self, from: data)
            return Dictionary(list.map { ($0.airline.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        } catch {
            assertionFailure("Bad livery_seed.json: \(error)")
            return [:]
        }
    }()
}
