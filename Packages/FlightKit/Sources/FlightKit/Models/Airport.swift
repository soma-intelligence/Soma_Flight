import Foundation

public struct Airport: Codable, Sendable, Hashable, Identifiable {
    /// ICAO code.
    public var id: String
    public var iata: String?
    public var name: String
    public var city: String
    public var country: String
    public var lat: Double
    public var lon: Double
    public var tz: String

    public init(id: String, iata: String? = nil, name: String, city: String, country: String, lat: Double, lon: Double, tz: String) {
        self.id = id; self.iata = iata; self.name = name; self.city = city
        self.country = country; self.lat = lat; self.lon = lon; self.tz = tz
    }

    public var timeZone: TimeZone { TimeZone(identifier: tz) ?? .gmt }
}
