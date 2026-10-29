import MapKit
import simd
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

/// The map's whole size and the part of it left visible by the bars and the sheet (its safe area), in points.
public struct GlobeViewport: Equatable, Sendable {
    public var size: CGSize
    public var visible: CGRect

    public init(size: CGSize, visible: CGRect) {
        self.size = size; self.visible = visible
    }

    /// An iPhone 17 Pro in portrait with the sheet at its medium detent (the map ends 44 pt under the
    /// sheet's top): the starting guess before the map has measured itself.
    public static let phone = GlobeViewport(size: CGSize(width: 402, height: 495),
                                            visible: CGRect(x: 0, y: 62, width: 402, height: 389))
}

/// Satellite globe with route arcs, airport dots and live planes.
public struct GlobeMap: View {
    var routes: [Route]
    var planes: [FlightAnnotationModel]
    var airports: [Airport]
    @Binding var selection: GlobeSelection?
    var focus: GlobeFocus?
    var recenter: Int
    var labels: Bool
    @State private var position: MapCameraPosition
    @State private var viewport = GlobeViewport.phone

    /// - Parameters:
    ///   - focus: moves the camera onto an arc or an airport; back to nil returns to the whole globe.
    ///   - recenter: bump it to move the camera back onto the same focus after the user panned away.
    ///   - labels: place names over the imagery.
    public init(routes: [Route], planes: [FlightAnnotationModel], airports: [Airport], selection: Binding<GlobeSelection?>,
                focus: GlobeFocus? = nil, recenter: Int = 0, labels: Bool = false) {
        self.routes = routes; self.planes = planes; self.airports = airports
        self._selection = selection
        self.focus = focus; self.recenter = recenter; self.labels = labels
        let start = focus.map { Self.camera(for: $0, in: .phone) } ?? Self.camera(routes: routes, planes: planes, airports: airports)
        _position = State(initialValue: .camera(start))
    }

    /// MapKit's vertical field of view across the whole map view, measured on the iPhone 17 Pro simulator
    /// from where San Francisco and Paris land (a focal length of about 980 pt for a 495 pt tall map).
    static let fieldOfView = 28.5 * .pi / 180
    /// Space kept between the arc and the edges of the visible area: an end's dot and its code.
    static let fitMargin: CGFloat = 36
    /// Measured: zoomed far out over high latitudes, MapKit has drawn the centre coordinate up to about
    /// this much below the middle of the visible area (none close in). The fit keeps it spare at the bottom, so
    /// the arc stays above the sheet wherever MapKit puts it.
    static let farZoomDrop: CGFloat = 70
    /// How far inside the globe's rim an arc's points must stay, so its ends are not squashed against it.
    static let rimClearance = 15.0 * .pi / 180
    static let earthRadius = 6_371_000.0
    static let minimumRouteDistance = 1_200_000.0

    /// The farthest MapKit takes the globe camera over a given latitude: it clamps the distance to about
    /// 40,000 km times the cosine of the centre's latitude (measured at 33, 43, 53 and 63 degrees north),
    /// and it keeps north up that far out (a heading is ignored).
    static func maximumDistance(at latitude: Double) -> Double {
        max(minimumRouteDistance, 40_000_000 * cos(latitude * .pi / 180) * 0.99)
    }

    /// Close in on an airport. For an arc: centred on it, at the shortest distance that keeps every point
    /// of it inside the visible part of the map, clear of the globe's rim. An arc too wide for that even at
    /// MapKit's farthest over its middle (Paris to San Francisco over Baffin Island) is seen from further
    /// south, where MapKit lets the camera go farther out, and nudged sideways to centre it.
    static func camera(for focus: GlobeFocus, in viewport: GlobeViewport) -> MapCamera {
        switch focus {
        case .route(let r):
            let pts = [r.from] + r.runs.flatMap { $0 } + [r.to]
            let mid = sphericalMean(pts) ?? r.from
            let nudges = [0.0] + stride(from: 2.0, through: 12, by: 2).flatMap { [$0, -$0] }
            for south in stride(from: 0.0, through: 45, by: 5) {
                for east in nudges {
                    let center = offset(mid, south: south, east: east)
                    if let d = closestFit(pts, center: center, in: viewport) {
                        return MapCamera(centerCoordinate: center, distance: d, heading: 0, pitch: 0)
                    }
                }
            }
            let far = offset(mid, south: 30, east: 0)
            return MapCamera(centerCoordinate: far, distance: maximumDistance(at: far.latitude), heading: 0, pitch: 0)
        case .airport(let a):
            return MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon),
                             distance: 22_000, heading: 0, pitch: 0)
        }
    }

    /// The shortest camera distance at which every point fits, nil when none up to MapKit's limit does.
    private static func closestFit(_ pts: [CLLocationCoordinate2D], center: CLLocationCoordinate2D,
                                   in viewport: GlobeViewport) -> Double? {
        func ok(_ d: Double) -> Bool {
            fits(pts, camera: MapCamera(centerCoordinate: center, distance: d, heading: 0, pitch: 0), in: viewport)
        }
        var lo = minimumRouteDistance, hi = maximumDistance(at: center.latitude)
        if ok(lo) { return lo }
        guard ok(hi) else { return nil }
        while hi - lo > 10_000 {
            let mid = (lo + hi) / 2
            if ok(mid) { hi = mid } else { lo = mid }
        }
        return hi
    }

    /// The point `south` degrees of arc due south of `p`, then `east` degrees of arc due east of that.
    static func offset(_ p: CLLocationCoordinate2D, south: Double, east: Double) -> CLLocationCoordinate2D {
        func move(_ p: CLLocationCoordinate2D, bearing: Double, by deg: Double) -> CLLocationCoordinate2D {
            guard deg != 0 else { return p }
            let la = p.latitude * .pi / 180, lo = p.longitude * .pi / 180, b = bearing * .pi / 180, d = deg * .pi / 180
            let la2 = asin(sin(la) * cos(d) + cos(la) * sin(d) * cos(b))
            let lo2 = lo + atan2(sin(b) * sin(d) * cos(la), cos(d) - sin(la) * sin(la2))
            return CLLocationCoordinate2D(latitude: la2 * 180 / .pi, longitude: remainder(lo2 * 180 / .pi, 360))
        }
        return move(move(p, bearing: 180, by: south), bearing: east >= 0 ? 90 : 270, by: abs(east))
    }

    /// The part of the visible area the arc must stay in.
    static func fitBox(_ viewport: GlobeViewport) -> CGRect {
        let box = viewport.visible.insetBy(dx: fitMargin, dy: fitMargin)
        return CGRect(x: box.minX, y: box.minY, width: box.width, height: max(0, box.height - farZoomDrop))
    }

    static func fits(_ pts: [CLLocationCoordinate2D], camera: MapCamera, in viewport: GlobeViewport) -> Bool {
        let box = fitBox(viewport)
        return pts.allSatisfy { p in project(p, camera: camera, in: viewport).map(box.contains) ?? false }
    }

    /// Where a coordinate lands in the map view for a straight-down camera, in points; nil when it is
    /// behind the globe or within `rimClearance` of its rim, where it would be squashed against the edge.
    /// The camera's centre coordinate lands in the middle of the visible area, as MapKit places it.
    static func project(_ p: CLLocationCoordinate2D, camera: MapCamera, in viewport: GlobeViewport) -> CGPoint? {
        let c = unit(camera.centerCoordinate), q = unit(p)
        let lon = camera.centerCoordinate.longitude * .pi / 180
        let east = SIMD3(-sin(lon), cos(lon), 0)
        let north = simd_cross(c, east)
        // Heading turns the view clockwise: the screen's up points `heading` degrees east of north.
        let h = camera.heading * .pi / 180
        let up = north * cos(h) + east * sin(h), right = east * cos(h) - north * sin(h)
        let r = earthRadius, eye = c * (r + camera.distance)
        // Visible only well inside the horizon circle.
        let horizon = acos(r / (r + camera.distance))
        guard acos(max(-1, min(1, simd_dot(c, q)))) < horizon - rimClearance else { return nil }
        let v = q * r - eye
        let depth = -simd_dot(v, c)
        guard depth > 0 else { return nil }
        let focal = Double(viewport.size.height) / 2 / tan(fieldOfView / 2)
        return CGPoint(x: Double(viewport.visible.midX) + simd_dot(v, right) / depth * focal,
                       y: Double(viewport.visible.midY) - simd_dot(v, up) / depth * focal)
    }

    private static func unit(_ p: CLLocationCoordinate2D) -> SIMD3<Double> {
        let la = p.latitude * .pi / 180, lo = p.longitude * .pi / 180
        return SIMD3(cos(la) * cos(lo), cos(la) * sin(lo), sin(la))
    }

    /// Mean on the unit sphere, so points across the antimeridian average correctly.
    static func sphericalMean(_ pts: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard !pts.isEmpty else { return nil }
        let s = pts.reduce(SIMD3<Double>()) { $0 + unit($1) }
        guard simd_length(s) > 1e-9 else { return nil }
        return CLLocationCoordinate2D(latitude: atan2(s.z, (s.x * s.x + s.y * s.y).squareRoot()) * 180 / .pi,
                                      longitude: atan2(s.y, s.x) * 180 / .pi)
    }

    /// Far enough out to see the whole globe, centred on what is shown (North America when empty).
    static func camera(routes: [Route], planes: [FlightAnnotationModel], airports: [Airport]) -> MapCamera {
        var pts = routes.flatMap { [$0.from, $0.to] } + planes.map(\.coordinate)
        if pts.isEmpty { pts = airports.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }
        let center = sphericalMean(pts) ?? CLLocationCoordinate2D(latitude: 39, longitude: -98)
        return MapCamera(centerCoordinate: center, distance: 22_000_000, heading: 0, pitch: 0)
    }

    private func moveToFocus() {
        withAnimation(.smooth(duration: 0.9)) {
            position = .camera(focus.map { Self.camera(for: $0, in: viewport) }
                ?? Self.camera(routes: routes, planes: planes, airports: airports))
        }
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
        .onChange(of: focus) { moveToFocus() }
        .onChange(of: recenter) { moveToFocus() }
        .onGeometryChange(for: GlobeViewport.self) { proxy in
            // The map lays out inside the safe area and draws under it; the insets give back the whole view.
            let i = proxy.safeAreaInsets
            return GlobeViewport(size: CGSize(width: proxy.size.width + i.leading + i.trailing,
                                              height: proxy.size.height + i.top + i.bottom),
                                 visible: CGRect(x: i.leading, y: i.top, width: proxy.size.width, height: proxy.size.height))
        } action: { new in
            viewport = new
            // The sheet settled on another detent: refit, unless the user has moved the globe.
            if let focus, !position.positionedByUser {
                        position = .camera(Self.camera(for: focus, in: new))
            }
        }
        .mapControls {
            MapCompass()
            MapPitchToggle()
        }
    }
}

#if DEBUG
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
#endif
