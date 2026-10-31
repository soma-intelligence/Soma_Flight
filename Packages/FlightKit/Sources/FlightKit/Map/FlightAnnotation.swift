import CoreLocation
import SwiftUI

/// A plane to draw on the globe.
public struct FlightAnnotationModel: Identifiable, Hashable, Sendable {
    public var id: Flight.ID
    public var ident: String
    public var latitude: Double
    public var longitude: Double
    /// Degrees clockwise from north.
    public var heading: Double
    public var level: DelayLevel
    /// A friend's plane (the Friends tab): drawn in the friends colour.
    public var isFriend: Bool
    /// Placed by `FlightEstimate` (no live position to be had): drawn hollow and dimmer.
    public var isEstimated: Bool

    public init(id: Flight.ID, ident: String, coordinate: CLLocationCoordinate2D, heading: Double, level: DelayLevel,
                isFriend: Bool = false, isEstimated: Bool = false) {
        self.id = id; self.ident = ident; self.isFriend = isFriend; self.isEstimated = isEstimated
        self.latitude = coordinate.latitude; self.longitude = coordinate.longitude
        self.heading = heading; self.level = level
    }

    /// From a flight's last position; nil when the flight has none.
    public init?(flight: Flight, isFriend: Bool = false) {
        guard let p = flight.position else { return nil }
        self.init(id: flight.id, ident: flight.ident, coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon),
                  heading: p.heading ?? 0, level: flight.level, isFriend: isFriend)
    }

    public var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Plane glyph turned to its heading, filled with the delay colour and rimmed so it reads on imagery.
public struct FlightAnnotation: View {
    var model: FlightAnnotationModel
    var selected: Bool

    public init(model: FlightAnnotationModel, selected: Bool = false) {
        self.model = model; self.selected = selected
    }

    public var body: some View {
        // The SF Symbol points east; rotate so 0 means north.
        Image(systemName: "airplane")
            .scaledFont(selected ? 22 : 17, weight: .bold)
            .foregroundStyle(model.isFriend ? Theme.friend : model.level == .onTime ? Color.white : model.level.color)
            .opacity(model.isEstimated ? 0.7 : 1)
            .shadow(color: .black.opacity(0.6), radius: 1.5)
            .rotationEffect(.degrees(model.heading - 90))
            .padding(6)
            .background(Circle().fill(.black.opacity(selected ? 0.45 : 0)))
            // An estimate wears a dashed ring, so it never reads as a live position.
            .overlay(Circle().strokeBorder(Color.white.opacity(model.isEstimated ? 0.7 : 0),
                                           style: StrokeStyle(lineWidth: 1.2, dash: [3, 3])))
            .animation(.snappy, value: selected)
            .accessibilityLabel(Text(model.isEstimated ? "\(model.ident), estimated position" : model.ident))
    }
}
