import Foundation

/// `#RRGGBB`.
public typealias HexColor = String

/// How an airline paints an aircraft. For now only the plain scheme's fields (fuselage top, belly and
/// where it splits, engines); stripes, tail paint and titles come with the livery renderer (plan Task 12)
/// on this same type.
public struct Livery: Codable, Sendable, Hashable {
    public var airline: String
    public var fuselageTop: HexColor
    public var belly: HexColor
    /// Fraction of fuselage height, from the bottom, where the belly colour stops.
    public var bellySplit: Double
    public var engines: HexColor

    public init(airline: String, fuselageTop: HexColor, belly: HexColor, bellySplit: Double, engines: HexColor) {
        self.airline = airline; self.fuselageTop = fuselageTop; self.belly = belly
        self.bellySplit = bellySplit; self.engines = engines
    }

    /// White top, light grey belly, grey engines.
    public static let plain = Livery(airline: "", fuselageTop: "#F7F7F8", belly: "#D5D8DC", bellySplit: 0.3, engines: "#C4C8CE")
}
