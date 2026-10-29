import MapKit
import SwiftUI

/// A route arc on the globe. The arc is computed once, at init.
public struct Route: Identifiable, Hashable, Sendable {
    public var id: String
    public let from: CLLocationCoordinate2D
    public let to: CLLocationCoordinate2D
    public var level: DelayLevel
    public var isPast: Bool
    /// Great-circle runs from the Rust core, normalised and split at the antimeridian for MapKit.
    public let runs: [[CLLocationCoordinate2D]]

    public init(id: String? = nil, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, level: DelayLevel, isPast: Bool) {
        self.from = from; self.to = to; self.level = level; self.isPast = isPast
        self.id = id ?? "\(from.latitude),\(from.longitude)-\(to.latitude),\(to.longitude)-\(isPast)"
        let n = max(16, min(128, Int(distanceKm(from, to) / 80)))
        self.runs = mapSegments(greatCircle(from: from, to: to, segments: n))
    }

    // Runs derive from the endpoints, so equality skips them.
    public static func == (a: Route, b: Route) -> Bool {
        a.id == b.id && a.level == b.level && a.isPast == b.isPast
            && a.from.latitude == b.from.latitude && a.from.longitude == b.from.longitude
            && a.to.latitude == b.to.latitude && a.to.longitude == b.to.longitude
    }

    public func hash(into h: inout Hasher) {
        h.combine(id); h.combine(level); h.combine(isPast)
        h.combine(from.latitude); h.combine(from.longitude); h.combine(to.latitude); h.combine(to.longitude)
    }
}

/// What the user tapped on the globe. (Named apart from MapKit's generic `MapSelection`.)
public enum GlobeSelection: Hashable, Sendable {
    case airport(Airport.ID)
    case flight(Flight.ID)
}

/// What the shell wants the camera on: one flight's arc or one airport.
public enum GlobeFocus: Hashable, Sendable {
    case route(Route)
    case airport(Airport)
}

/// Satellite globe with route arcs, airport dots and live planes.
public struct GlobeMap: View {
    var routes: [Route]
    var planes: [FlightAnnotationModel]
    var airports: [Airport]
    @Binding var selection: GlobeSelection?
    var focus: GlobeFocus?
    var labels: Bool
    @State private var position: MapCameraPosition

    /// - Parameters:
    ///   - focus: moves the camera onto an arc or an airport; back to nil returns to the whole globe.
    ///   - labels: place names over the imagery.
    public init(routes: [Route], planes: [FlightAnnotationModel], airports: [Airport], selection: Binding<GlobeSelection?>,
                focus: GlobeFocus? = nil, labels: Bool = false) {
        self.routes = routes; self.planes = planes; self.airports = airports
        self._selection = selection
        self.focus = focus; self.labels = labels
        let start = focus.map(Self.camera(for:)) ?? Self.camera(routes: routes, planes: planes, airports: airports)
        _position = State(initialValue: .camera(start))
    }

    /// Centred on the middle of the arc, far enough out to see both ends; close in on an airport.
    static func camera(for focus: GlobeFocus) -> MapCamera {
        switch focus {
        case .route(let r):
            let pts = r.runs.flatMap { $0 }
            let mid = pts.isEmpty ? r.from : pts[pts.count / 2]
            let span = distanceKm(r.from, r.to) * 1000
            return MapCamera(centerCoordinate: mid, distance: min(30_000_000, max(1_200_000, span * 2.8)), heading: 0, pitch: 0)
        case .airport(let a):
            return MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon),
                             distance: 22_000, heading: 0, pitch: 0)
        }
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
        .mapStyle(labels ? .hybrid(elevation: .realistic, pointsOfInterest: .excludingAll) : .imagery(elevation: .realistic))
        .onChange(of: routes) {
            // Follow new content unless the user has panned or zoomed the globe, or a focus holds the camera.
            if focus == nil, !position.positionedByUser {
                position = .camera(Self.camera(routes: routes, planes: planes, airports: airports))
            }
        }
        .onChange(of: focus) {
            withAnimation(.smooth(duration: 0.9)) {
                position = .camera(focus.map(Self.camera(for:)) ?? Self.camera(routes: routes, planes: planes, airports: airports))
            }
        }
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
