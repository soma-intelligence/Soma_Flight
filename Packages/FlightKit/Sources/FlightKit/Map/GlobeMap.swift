import MapKit
import SwiftUI

/// A route arc on the globe.
public struct Route: Identifiable, Hashable, Sendable {
    public var id: String
    public var fromLatitude: Double, fromLongitude: Double
    public var toLatitude: Double, toLongitude: Double
    public var level: DelayLevel
    public var isPast: Bool

    public init(id: String? = nil, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, level: DelayLevel, isPast: Bool) {
        self.fromLatitude = from.latitude; self.fromLongitude = from.longitude
        self.toLatitude = to.latitude; self.toLongitude = to.longitude
        self.level = level; self.isPast = isPast
        self.id = id ?? "\(from.latitude),\(from.longitude)-\(to.latitude),\(to.longitude)-\(isPast)"
    }

    public var from: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: fromLatitude, longitude: fromLongitude) }
    public var to: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: toLatitude, longitude: toLongitude) }

    /// Great-circle runs from the Rust core, normalised and split at the antimeridian for MapKit.
    public var runs: [[CLLocationCoordinate2D]] {
        let n = max(16, min(128, Int(distanceKm(from, to) / 80)))
        return mapSegments(greatCircle(from: from, to: to, segments: n))
    }
}

/// What the user tapped on the globe. (Named apart from MapKit's generic `MapSelection`.)
public enum GlobeSelection: Hashable, Sendable {
    case airport(Airport.ID)
    case flight(Flight.ID)
}

/// Satellite globe with route arcs, airport dots and live planes.
public struct GlobeMap: View {
    var routes: [Route]
    var planes: [FlightAnnotationModel]
    var airports: [Airport]
    @Binding var selection: GlobeSelection?
    @State private var position: MapCameraPosition

    public init(routes: [Route], planes: [FlightAnnotationModel], airports: [Airport], selection: Binding<GlobeSelection?>) {
        self.routes = routes; self.planes = planes; self.airports = airports
        self._selection = selection
        _position = State(initialValue: .camera(Self.camera(routes: routes, planes: planes, airports: airports)))
    }

    /// Far enough out to see the whole globe, centred on what is shown (North America when empty).
    static func camera(routes: [Route], planes: [FlightAnnotationModel], airports: [Airport]) -> MapCamera {
        var pts = routes.flatMap { [$0.from, $0.to] } + planes.map(\.coordinate)
        if pts.isEmpty { pts = airports.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }
        var center = CLLocationCoordinate2D(latitude: 39, longitude: -98)
        if !pts.isEmpty {
            // Mean on the unit sphere so routes across the antimeridian centre correctly.
            var x = 0.0, y = 0.0, z = 0.0
            for p in pts {
                let la = p.latitude * .pi / 180, lo = p.longitude * .pi / 180
                x += cos(la) * cos(lo); y += cos(la) * sin(lo); z += sin(la)
            }
            let lon = atan2(y, x), hyp = (x * x + y * y).squareRoot()
            center = CLLocationCoordinate2D(latitude: atan2(z, hyp) * 180 / .pi, longitude: lon * 180 / .pi)
        }
        return MapCamera(centerCoordinate: center, distance: 22_000_000, heading: 0, pitch: 0)
    }

    public var body: some View {
        Map(position: $position, selection: $selection) {
            ForEach(routes) { route in
                ForEach(Array(route.runs.enumerated()), id: \.offset) { _, run in
                    MapPolyline(coordinates: run, contourStyle: .straight)
                        .stroke(route.isPast ? Color.white.opacity(0.55) : route.level.color,
                                style: StrokeStyle(lineWidth: route.isPast ? 1.2 : 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            ForEach(airports) { a in
                Annotation(a.iata ?? a.id, coordinate: CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon), anchor: .center) {
                    Circle()
                        .fill(.white)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1))
                        .padding(8)
                        .contentShape(Circle())
                }
                .annotationTitles(.visible)
                .tag(GlobeSelection.airport(a.id))
            }
            ForEach(planes) { p in
                Annotation(p.ident, coordinate: p.coordinate, anchor: .center) {
                    FlightAnnotation(model: p, selected: selection == .flight(p.id))
                }
                .annotationTitles(.hidden)
                .tag(GlobeSelection.flight(p.id))
            }
        }
        .mapStyle(.imagery(elevation: .realistic))
        .mapControls {
            MapCompass()
            MapPitchToggle()
        }
    }
}

#Preview {
    @Previewable @State var selection: GlobeSelection?
    let byID = Dictionary(uniqueKeysWithValues: PreviewData.airports.map { ($0.id, $0) })
    let coord = { (id: String) in CLLocationCoordinate2D(latitude: byID[id]!.lat, longitude: byID[id]!.lon) }
    GlobeMap(
        routes: [
            Route(from: coord("LFPG"), to: coord("KSFO"), level: .late, isPast: false),
            Route(from: coord("RJTT"), to: coord("KSFO"), level: .onTime, isPast: true),
            Route(from: coord("EGLL"), to: coord("KJFK"), level: .onTime, isPast: true),
        ],
        planes: PreviewData.followed.compactMap(FlightAnnotationModel.init(flight:)),
        airports: PreviewData.airports,
        selection: $selection
    )
    .ignoresSafeArea()
}
