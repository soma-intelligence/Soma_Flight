import MapKit
import OSLog
import simd
import SwiftUI

/// A route arc on the globe. The arc is computed once, at init.
public struct Route: Identifiable, Hashable, Sendable {
    public var id: String
    public let from: CLLocationCoordinate2D
    public let to: CLLocationCoordinate2D
    public var level: DelayLevel
    public var isPast: Bool
    /// A friend's flight (the Friends tab): drawn dashed in the friends colour.
    public var isFriend: Bool
    /// Great-circle runs from the Rust core, normalised and split at the antimeridian for MapKit.
    public let runs: [[CLLocationCoordinate2D]]

    public init(id: String? = nil, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, level: DelayLevel, isPast: Bool,
                isFriend: Bool = false) {
        self.from = from; self.to = to; self.level = level; self.isPast = isPast; self.isFriend = isFriend
        self.id = id ?? "\(from.latitude),\(from.longitude)-\(to.latitude),\(to.longitude)-\(isPast)"
        let n = max(16, min(128, Int(distanceKm(from, to) / 80)))
        self.runs = mapSegments(greatCircle(from: from, to: to, segments: n))
    }

    // Runs derive from the endpoints, so equality skips them.
    public static func == (a: Route, b: Route) -> Bool {
        a.id == b.id && a.level == b.level && a.isPast == b.isPast && a.isFriend == b.isFriend
            && a.from.latitude == b.from.latitude && a.from.longitude == b.from.longitude
            && a.to.latitude == b.to.latitude && a.to.longitude == b.to.longitude
    }

    public func hash(into h: inout Hasher) {
        h.combine(id); h.combine(level); h.combine(isPast); h.combine(isFriend)
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

/// One flight drawn alone: the globe fades every other arc, pin and plane while it is open.
public struct GlobeIsolation: Equatable, Sendable {
    public var route: Route
    public var airports: [Airport]
    public var plane: FlightAnnotationModel?

    public init(route: Route, airports: [Airport], plane: FlightAnnotationModel? = nil) {
        self.route = route; self.airports = airports; self.plane = plane
    }

    /// The arc `other` draws the same airport pair as this flight, whichever way it was flown (Passport
    /// keeps one arc per pair, under its own id).
    func isSameArc(_ other: Route) -> Bool {
        other.id == route.id
            || (Self.same(other.from, route.from) && Self.same(other.to, route.to))
            || (Self.same(other.from, route.to) && Self.same(other.to, route.from))
    }

    static func same(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) < 1e-6 && abs(a.longitude - b.longitude) < 1e-6
    }
}

/// The map's whole size and the part of it left visible by the bars and the sheet (its safe area), in points.
public struct GlobeViewport: Equatable, Sendable {
    public var size: CGSize
    public var visible: CGRect
    /// How MapKit on this platform clamps the camera far out: the farthest distance is this many metres
    /// times the cosine of the centre's latitude.
    public var farLimit: Double

    /// - Parameter farLimit: nil is the iPhone's clamp for a map of `size` (`phoneFarLimit(_:)`).
    public init(size: CGSize, visible: CGRect, farLimit: Double? = nil) {
        self.size = size; self.visible = visible
        self.farLimit = farLimit ?? Self.phoneFarLimit(size)
    }

    /// The iPhone's clamp measured on a 402 x 495 pt map (the map then ended at the medium sheet): about
    /// 40,000 km at the equator.
    static let phoneFarLimit = 40_000_000.0
    static let phoneMeasuredSize = CGSize(width: 402, height: 495)

    /// The iPhone clamp for a map of `size`. NOT YET MEASURED beyond the one size above: it assumes the
    /// iPhone follows the Mac's measured law (the clamp grows with height / width, so the globe far out
    /// keeps the same share of the map's width), scaled to go through the iPhone's measured point. The
    /// full-screen map (402 x 874) then clamps at about 70,600 km. If MapKit clamps nearer, the camera it
    /// applies is closer than asked and a long arc spills under the sheet; `GlobeMap` logs that in Debug
    /// builds ("clamped"). To measure: ask for a 400,000 km camera on the full-screen map and read back.
    static func phoneFarLimit(_ size: CGSize) -> Double {
        guard size.width > 0, size.height > 0 else { return phoneFarLimit }
        let m = phoneMeasuredSize
        return phoneFarLimit * Double(size.height / m.height) / Double(size.width / m.width)
    }

    /// The Mac's MapKit (`#if os(macOS)` in `GlobeMap`; Catalyst and visionOS take the iPhone values).
    /// Measured by asking for a 400,000 km camera and reading back the one MapKit applied, at four
    /// latitudes, in windows with the 372 pt panel on the left (map width x height, farthest distance at
    /// the equator, in km):
    ///
    ///     900 x 640: 26,410     1000 x 1000: 37,140    1100 x 650: 21,946
    ///     1180 x 799: 25,148    1300 x 1009: 28,826    1400 x 700: 18,570
    ///     1500 x 632: 15,648    1600 x 900: 20,891     1700 x 1000: 21,847
    ///
    /// Every row is 37,130 km x height / width within 0.1% (the panel's inset plays no part), and every
    /// latitude follows the cosine. Below the clamp MapKit puts the centre coordinate exactly in the middle
    /// of the visible area; past it, it does not, which is what an earlier one-size estimate mistook for an
    /// offset. Sizes outside 900 to 1700 wide and 632 to 1009 tall are extrapolated.
    public static func mac(size: CGSize, visible: CGRect) -> GlobeViewport {
        GlobeViewport(size: size, visible: visible, farLimit: macFarLimit(size))
    }

    /// The Mac clamp's metres at the equator for a map of `size`.
    static func macFarLimit(_ size: CGSize) -> Double {
        guard size.width > 0, size.height > 0 else { return phoneFarLimit }
        return 37_130_000 * Double(size.height) / Double(size.width)
    }

    /// An iPhone 17 Pro in portrait, the map full screen with the sheet at its medium detent: the starting
    /// guess before the map has measured itself (the visible height is the earlier guess, kept).
    public static let phone = GlobeViewport(size: CGSize(width: 402, height: 874),
                                            visible: CGRect(x: 0, y: 62, width: 402, height: 389))
}

/// The iPhone map's safe area when it differs from the area the camera frames (`ShellModel.globeInsets`),
/// in the map's own points. MapKit draws the camera's centre in the middle of the safe area, so the two
/// share a centre; the safe area's bottom is where MapKit puts its logo and Legal link.
public struct GlobeInsets: Equatable, Sendable {
    /// How far the map is drawn above the screen's top (and ends above its bottom), so its safe area can
    /// reach above the screen. The caller offsets the map by it.
    public var lift: CGFloat
    /// The framed area: the camera fits arcs and airports between these insets.
    public var framedTop: CGFloat
    public var framedBottom: CGFloat
    /// The safe area MapKit gets, around the same centre.
    public var safeTop: CGFloat
    public var safeBottom: CGFloat

    public init(lift: CGFloat, framedTop: CGFloat, framedBottom: CGFloat, safeTop: CGFloat, safeBottom: CGFloat) {
        self.lift = lift; self.framedTop = framedTop; self.framedBottom = framedBottom
        self.safeTop = safeTop; self.safeBottom = safeBottom
    }
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
    /// Tilts the camera for a 3D view; nil leaves the pitch to MapKit's own toggle (the Mac).
    var threeD: Bool?
    var isolation: GlobeIsolation?
    /// Airports drawn as status dots (green, amber, red) instead of white ones: the Airports list.
    var airportStatus: [String: AirportStatusLevel]
    /// How far the visible part of the map stops above its bottom edge (the iPhone sheet). The map keeps
    /// its full size and only its safe area moves, so a detent change never resizes the map.
    var bottomInset: CGFloat
    /// The iPhone's safe area apart from the framed area; nil frames the safe area itself.
    var insets: GlobeInsets?
    /// Where an outside `MapCompass(scope:)` finds this map; nil keeps MapKit's own compass.
    var controlsScope: Namespace.ID?
    @State private var position: MapCameraPosition
    /// How much of everything outside the isolated flight shows: 1 all of it, 0 none. Stepped by
    /// `fade(to:)`, as MapKit does not animate its overlays' colours.
    @State private var fade: Double = 1
    /// The isolation being drawn; it stays while the rest fades back in.
    @State private var shown: GlobeIsolation?
    @State private var fadeTask: Task<Void, Never>?
    @State private var focusTask: Task<Void, Never>?
    /// A refit waiting for the visible area to stop moving.
    @State private var refitTask: Task<Void, Never>?
    /// The visible area the camera already aims at while the safe area glides to a new `bottomInset`;
    /// geometry changes during the glide do not refit.
    @State private var aimedAt: CGRect?
    /// Where the camera settled last, so the 3D switch tilts the view the user is looking at.
    @State private var settled: MapCamera?
    @State private var viewport = GlobeViewport.phone

    /// - Parameters:
    ///   - focus: moves the camera onto an arc or an airport; back to nil returns to the whole globe.
    ///   - recenter: bump it to move the camera back onto the same focus after the user panned away.
    ///   - labels: place names over the imagery.
    ///   - isolation: one flight drawn alone, the rest faded out; nil draws everything.
    ///   - bottomInset: the part of the map's bottom hidden by a sheet, added to its safe area. A change
    ///     glides the globe up or down and springs the camera onto the new fit.
    ///   - insets: the map's whole safe area, apart from the framed area (the iPhone, where MapKit's logo
    ///     follows the sheet); it replaces `bottomInset` and the system safe areas, which the caller ignores.
    ///   - controlsScope: a `mapScope` the caller places `MapCompass(scope:)` in; the map then draws none.
    public init(routes: [Route], planes: [FlightAnnotationModel], airports: [Airport], selection: Binding<GlobeSelection?>,
                focus: GlobeFocus? = nil, recenter: Int = 0, labels: Bool = false, threeD: Bool? = nil,
                isolation: GlobeIsolation? = nil, bottomInset: CGFloat = 0, insets: GlobeInsets? = nil,
                controlsScope: Namespace.ID? = nil, airportStatus: [String: AirportStatusLevel] = [:]) {
        self.bottomInset = insets?.framedBottom ?? bottomInset
        self.insets = insets
        self.controlsScope = controlsScope
        self.airportStatus = airportStatus
        self.routes = routes; self.planes = planes; self.airports = airports
        self._selection = selection
        self.focus = focus; self.recenter = recenter; self.labels = labels; self.threeD = threeD
        self.isolation = isolation
        // Cheap on purpose: SwiftUI evaluates this on every parent update that rebuilds the view, though
        // only the first value is kept. A focus present from the start is fitted once, on appear.
        _position = State(initialValue: .camera(Self.camera(routes: routes, planes: planes, airports: airports)))
    }

    /// The tilt of the 3D view, degrees from straight down.
    static let threeDPitch: Double = 60

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

    /// The farthest MapKit takes the globe camera over a given latitude: it clamps the distance to the
    /// viewport's `farLimit` times the cosine of the centre's latitude, and it keeps north up that far out
    /// (a heading is ignored). On the iPhone the limit was about 40,000 km on a 402 x 495 pt map (measured
    /// at 33, 43, 53 and 63 degrees north) and is assumed to follow the map's aspect as on the Mac
    /// (`GlobeViewport.phoneFarLimit(_:)`, `GlobeViewport.mac`).
    static func maximumDistance(at latitude: Double, in viewport: GlobeViewport = .phone) -> Double {
        max(minimumRouteDistance, viewport.farLimit * cos(latitude * .pi / 180) * 0.99)
    }

    /// Close in on an airport. For an arc: centred on it, at the shortest distance that keeps every point
    /// of it inside the visible part of the map, clear of the globe's rim. An arc too wide for that even at
    /// MapKit's farthest over its middle (Paris to San Francisco over Baffin Island) is seen from nearer
    /// the equator, where MapKit lets the camera go farther out, and nudged sideways to centre it. When no
    /// camera fits, the one that overflows least is kept.
    static func camera(for focus: GlobeFocus, in viewport: GlobeViewport) -> MapCamera {
        switch focus {
        case .route(let r):
            let pts = [r.from] + r.runs.flatMap { $0 } + [r.to]
            let mid = sphericalMean(pts) ?? r.from
            var best: (overflow: Double, camera: MapCamera)?
            for center in candidateCenters(around: mid) {
                if let d = closestFit(pts, center: center, in: viewport) {
                    return MapCamera(centerCoordinate: center, distance: d, heading: 0, pitch: 0)
                }
                let far = MapCamera(centerCoordinate: center, distance: maximumDistance(at: center.latitude, in: viewport), heading: 0, pitch: 0)
                let o = overflow(pts, camera: far, in: viewport)
                if best == nil || o < best!.overflow { best = (o, far) }
            }
            return best?.camera ?? MapCamera(centerCoordinate: mid, distance: maximumDistance(at: mid.latitude, in: viewport), heading: 0, pitch: 0)
        case .airport(let a):
            return MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon),
                             distance: 22_000, heading: 0, pitch: 0)
        }
    }

    /// Centres to try, in order: the arc's middle, then steps of 5 degrees toward the equator (north for a
    /// southern arc), each with sideways nudges. Steps stop at the equator's far side by 10 degrees.
    static func candidateCenters(around mid: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let towardEquator = mid.latitude >= 0 ? 1.0 : -1.0
        let reach = min(45, abs(mid.latitude) + 10)
        let nudges = [0.0] + stride(from: 2.0, through: 12, by: 2).flatMap { [$0, -$0] }
        return stride(from: 0.0, through: reach, by: 5).flatMap { step in
            nudges.map { offset(mid, south: step * towardEquator, east: $0) }
        }
    }

    /// How far the arc spills out of the fit box, as a fraction of the box's size (0 when it fits); a
    /// point hidden behind the globe counts as a full box.
    static func overflow(_ pts: [CLLocationCoordinate2D], camera: MapCamera, in viewport: GlobeViewport) -> Double {
        let box = fitBox(viewport)
        guard box.width > 0, box.height > 0 else { return .infinity }
        return pts.reduce(0) { worst, p in
            guard let q = project(p, camera: camera, in: viewport) else { return max(worst, 1) }
            let dx = max(box.minX - q.x, q.x - box.maxX, 0) / box.width
            let dy = max(box.minY - q.y, q.y - box.maxY, 0) / box.height
            return max(worst, Double(max(dx, dy)))
        }
    }

    /// The shortest camera distance at which every point fits, nil when none up to MapKit's limit does.
    private static func closestFit(_ pts: [CLLocationCoordinate2D], center: CLLocationCoordinate2D,
                                   in viewport: GlobeViewport) -> Double? {
        func ok(_ d: Double) -> Bool {
            fits(pts, camera: MapCamera(centerCoordinate: center, distance: d, heading: 0, pitch: 0), in: viewport)
        }
        var lo = minimumRouteDistance, hi = maximumDistance(at: center.latitude, in: viewport)
        if ok(lo) { return lo }
        guard ok(hi) else { return nil }
        while hi - lo > 10_000 {
            let mid = (lo + hi) / 2
            if ok(mid) { hi = mid } else { lo = mid }
        }
        return hi
    }

    /// The point `south` degrees of arc due south of `p` (north when negative), then `east` degrees of
    /// arc due east of that (west when negative).
    static func offset(_ p: CLLocationCoordinate2D, south: Double, east: Double) -> CLLocationCoordinate2D {
        func move(_ p: CLLocationCoordinate2D, bearing: Double, by deg: Double) -> CLLocationCoordinate2D {
            guard deg != 0 else { return p }
            let la = p.latitude * .pi / 180, lo = p.longitude * .pi / 180, b = bearing * .pi / 180, d = deg * .pi / 180
            let la2 = asin(sin(la) * cos(d) + cos(la) * sin(d) * cos(b))
            let lo2 = lo + atan2(sin(b) * sin(d) * cos(la), cos(d) - sin(la) * sin(la2))
            return CLLocationCoordinate2D(latitude: la2 * 180 / .pi, longitude: remainder(lo2 * 180 / .pi, 360))
        }
        return move(move(p, bearing: south >= 0 ? 180 : 0, by: abs(south)), bearing: east >= 0 ? 90 : 270, by: abs(east))
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

    #if DEBUG
    static let log = Logger(subsystem: "me.somalabs.flight", category: "globe")
    #endif

    /// The camera's move onto a new visible area (a detent that settled): a spring with no bounce.
    static let refitAnimation = Animation.spring(duration: 0.6, bounce: 0)
    /// How long the other flights take to fade out or back in.
    static let fadeDuration = 0.35

    /// How long a flight's card takes to rise or drop: the globe waits for it before fading or moving,
    /// so the map's redraws never share frames with the card's spring.
    static let cardSettle: Duration = .milliseconds(430)

    /// Steps `fade` to `target` along an ease in and out, about 15 times a second, once the card settled.
    private func fade(to target: Double) {
        fadeTask?.cancel()
        let start = fade
        guard start != target else {
            if target == 1 { shown = nil }
            return
        }
        let steps = max(1, Int(Self.fadeDuration * 15))
        fadeTask = Task { @MainActor in
            try? await Task.sleep(for: Self.cardSettle)
            if Task.isCancelled { return }
            for i in 1...steps {
                try? await Task.sleep(for: .seconds(Self.fadeDuration / Double(steps)))
                if Task.isCancelled { return }
                fade = GlobeLayers.eased(from: start, to: target, at: Double(i) / Double(steps))
            }
            if target == 1 { shown = nil }
        }
    }

    /// Follows a new isolation: a new flight swaps in at once, the rest fades out or back in.
    private func isolate(_ new: GlobeIsolation?) {
        if let new {
            shown = new
            fade(to: 0)
        } else {
            fade(to: 1)
        }
    }

    /// Springs the camera onto the focus's fit for the current visible area after `delay`, unless the
    /// user has moved the globe; a newer call replaces a waiting one.
    private func refit(after delay: Duration) {
        refitTask?.cancel()
        refitTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let focus, !position.positionedByUser else { return }
            withAnimation(Self.refitAnimation) { position = .camera(Self.camera(for: focus, in: viewport)) }
        }
    }

    /// Flies the camera onto the focus (or back over everything) once the card has settled.
    private func moveToFocus(after delay: Duration = cardSettle) {
        focusTask?.cancel()
        focusTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            let target = focus.map { Self.camera(for: $0, in: viewport) }
                ?? Self.camera(routes: routes, planes: planes, airports: airports)
            withAnimation(.smooth(duration: 0.9)) { position = .camera(target) }
        }
    }

    /// A friend's arc is dashed in the friends colour; a past one thin and white; a followed one in its delay colour.
    static func stroke(_ route: Route) -> Color {
        route.isFriend ? Theme.friend : route.isPast ? Color.white.opacity(0.55) : route.level.color
    }

    static func strokeStyle(_ route: Route) -> StrokeStyle {
        StrokeStyle(lineWidth: route.isPast ? 1.2 : route.isFriend ? 2 : 2.5, lineCap: .round, lineJoin: .round,
                    dash: route.isFriend ? [6, 5] : [])
    }

    public var body: some View {
        let layers = GlobeLayers(routes: routes, planes: planes, airports: airports, isolation: shown, fade: fade)
        Map(position: $position, selection: $selection, scope: controlsScope) {
            ForEach(layers.routes) { item in
                let route = item.route
                ForEach(Array(route.runs.enumerated()), id: \.offset) { _, run in
                    MapPolyline(coordinates: run, contourStyle: .straight)
                        .stroke(Self.stroke(route).opacity(item.opacity), style: Self.strokeStyle(route))
                }
            }
            ForEach(layers.airports) { item in
                let a = item.airport
                Annotation(a.iata ?? a.id, coordinate: CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon), anchor: .center) {
                    AirportDot(status: airportStatus[a.id])
                        .padding(8)
                        .contentShape(Circle())
                        .opacity(item.opacity)
                }
                // Close neighbours (SFO and OAK) keep their dots; only the busier one is labelled.
                .annotationTitles(item.titled ? .visible : .hidden)
                .tag(GlobeSelection.airport(a.id))
            }
            ForEach(layers.planes) { item in
                let p = item.plane
                Annotation(p.ident, coordinate: p.coordinate, anchor: .center) {
                    FlightAnnotation(model: p, selected: selection == .flight(p.id))
                        .opacity(item.opacity)
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
        .onChange(of: recenter) { moveToFocus(after: .zero) }
        .onChange(of: isolation) { _, new in isolate(new) }
        .onAppear {
            if let focus { position = .camera(Self.camera(for: focus, in: viewport)) }
            if let isolation { shown = isolation; fade = 0 }
        }
        .onGeometryChange(for: GlobeViewport.self) { proxy in
            // The map lays out inside the safe area and draws under it; the insets give back the whole view.
            let i = proxy.safeAreaInsets
            let size = CGSize(width: proxy.size.width + i.leading + i.trailing, height: proxy.size.height + i.top + i.bottom)
            var visible = CGRect(x: i.leading, y: i.top, width: proxy.size.width, height: proxy.size.height)
            // A safe area wider than the framed area (the iPhone): the camera still frames the latter.
            if let insets {
                visible.origin.y = insets.framedTop
                visible.size.height = max(0, size.height - insets.framedTop - insets.framedBottom)
            }
            #if os(macOS)  // deliberately the Mac only: Catalyst and visionOS keep the iPhone clamp
            return GlobeViewport.mac(size: size, visible: visible)
            #else
            return GlobeViewport(size: size, visible: visible)
            #endif
        } action: { new in
            let moved = new.visible != viewport.visible
            viewport = new
            // Frames of a glide the camera already aims at; otherwise (a rotation, a resized Mac window)
            // the camera refits once the visible area holds still, never frame by frame.
            guard moved, aimedAt == nil else { return }
            refit(after: .milliseconds(40))
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            settled = context.camera
            #if DEBUG
            // The phone's far clamp is a model past its one measured size: say when MapKit went nearer.
            if let asked = position.camera, asked.distance > context.camera.distance * 1.05 {
                Self.log.debug("clamped: asked \(Int(asked.distance / 1000)) km, got \(Int(context.camera.distance / 1000)) km at \(context.camera.centerCoordinate.latitude, format: .fixed(precision: 1))°, map \(Int(viewport.size.width)) x \(Int(viewport.size.height))")
            }
            #endif
        }
        // The inset changed (on the iPhone only when the screen's geometry does, never with the detent):
        // the camera springs at once onto the fit for the visible area the new inset leaves, while the
        // safe area glides there with the same spring. The area is taken from the whole map and the new
        // inset, not from the last reported one, which may be a frame in the middle of an earlier glide.
        .onChange(of: bottomInset) { _, new in
            var visible = viewport.visible
            visible.size.height = max(0, viewport.size.height - visible.minY - new)
            aimedAt = visible
            if let focus, !position.positionedByUser {
                let target = GlobeViewport(size: viewport.size, visible: visible, farLimit: viewport.farLimit)
                withAnimation(Self.refitAnimation) { position = .camera(Self.camera(for: focus, in: target)) }
            }
            // Once the glide is over, a visible area that ended elsewhere than aimed gets its own refit.
            refitTask?.cancel()
            refitTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                let missed = viewport.visible != aimedAt
                aimedAt = nil
                if missed { refit(after: .zero) }
            }
        }
        .onChange(of: threeD) { _, on in
            guard let on, let c = settled else { return }
            withAnimation(.smooth(duration: 0.8)) {
                position = .camera(MapCamera(centerCoordinate: c.centerCoordinate, distance: c.distance,
                                             heading: c.heading, pitch: on ? Self.threeDPitch : 0))
            }
        }
        .mapControls {
            if controlsScope == nil { MapCompass() }
            if threeD == nil { MapPitchToggle() }
        }
        .safeAreaPadding(.top, insets?.safeTop ?? 0)
        .safeAreaPadding(.bottom, insets?.safeBottom ?? bottomInset)
        // One spring for both edges, so the safe area's centre (the camera's) never moves as they glide.
        .animation(Self.refitAnimation, value: insets)
        .animation(Self.refitAnimation, value: bottomInset)
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
        planes: PreviewData.followed.compactMap { FlightAnnotationModel(flight: $0) },
        airports: PreviewData.airports,
        selection: $selection
    )
    .ignoresSafeArea()
}
#endif

/// An airport on the globe: a small white dot, or a larger coloured one when the Airports list gives it a status.
struct AirportDot: View {
    var status: AirportStatusLevel?

    var body: some View {
        if let status {
            Circle()
                .fill(AirportStatusColor.of(status))
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(.black.opacity(0.45), lineWidth: 1.5))
                .shadow(color: AirportStatusColor.of(status).opacity(0.6), radius: 3)
        } else {
            Circle()
                .fill(.white)
                .frame(width: 6, height: 6)
                .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1))
        }
    }
}
