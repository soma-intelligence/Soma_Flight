import Foundation

public struct Position: Codable, Sendable, Hashable {
    public var lat: Double
    public var lon: Double
    public var altitudeFt: Int?
    public var groundSpeedKt: Int?
    public var heading: Double?
    public var at: Date

    public init(lat: Double, lon: Double, altitudeFt: Int? = nil, groundSpeedKt: Int? = nil, heading: Double? = nil, at: Date) {
        self.lat = lat; self.lon = lon; self.altitudeFt = altitudeFt
        self.groundSpeedKt = groundSpeedKt; self.heading = heading; self.at = at
    }
}
