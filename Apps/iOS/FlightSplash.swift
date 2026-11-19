import SwiftUI

/// The first second and a half of a cold launch. It carries on from the launch screen (`LaunchMark`, the jet
/// tile, centred on black, 96 pt) without a jump: the first frame is that screen. A glint crosses the tile, then
/// the jet lifts off it, banks and climbs away along a curve, drawing a soft contrail; the empty tile swells and
/// dissolves while the black opens onto whatever is under it (the sign in globe or the home). Reduce Motion: the
/// tile, then a short plain fade. Skipped with `-noSplash YES` (Debug screenshot runs). The app under it is built
/// and live the whole time; the splash never waits on it and lets touches through from the moment it opens up.
struct FlightSplash: View {
    let finished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the first frame was drawn; nil until then, so the first frame is time zero.
    @State private var start: Date?

    /// The launch screen's tile, in points (`LaunchMark` is 96 pt).
    static let size: CGFloat = 96

    static var enabled: Bool {
        #if DEBUG
        !UserDefaults.standard.bool(forKey: "noSplash")
        #else
        true
        #endif
    }

    var body: some View {
        TimelineView(.animation) { context in
            SplashFrame(mark: Image("LaunchMark"),
                        time: start.map { context.date.timeIntervalSince($0) } ?? 0,
                        reduceMotion: reduceMotion)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task {
            start = .now
            await pause(SplashFrame.duration(reduceMotion: reduceMotion))
            finished()
        }
    }

    /// A pause that never throws: the splash always ends, even if its task is cancelled.
    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// One frame of the splash at `time` seconds, a pure function of time (so previews and renders can scrub it).
///
/// Timeline (full motion, 1.45 s):
/// - 0.00: the launch screen, pixel for pixel.
/// - 0.06 to 0.56: a glint crosses the tile along the jet's heading.
/// - 0.40 to 1.15: the jet lifts off the tile, accelerating along a climbing curve to the upper right, banking
///   into the turn and growing a little as it nears; a contrail draws itself behind it and thins from the start.
/// - 0.50 to 1.15: the empty tile swells (1 to 1.6) and dissolves.
/// - 0.70 to 1.40: the black fades out onto the app; the contrail fades with it.
struct SplashFrame: View {
    let mark: Image
    let time: Double
    let reduceMotion: Bool

    static func duration(reduceMotion: Bool) -> Double { reduceMotion ? 0.45 : 1.45 }

    private static let size = FlightSplash.size
    /// The tile's own background (top, middle and bottom of its gradient, read off `LaunchMark`), for the
    /// tile the jet leaves behind.
    private static let tileTop = Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255)
    private static let tileMiddle = Color(red: 21 / 255, green: 21 / 255, blue: 23 / 255)
    private static let tileBottom = Color(red: 9 / 255, green: 9 / 255, blue: 10 / 255)

    var body: some View {
        GeometryReader { proxy in
            if reduceMotion {
                reduced
            } else {
                full(in: proxy.size)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Reduce Motion

    private var reduced: some View {
        let fade = 1 - Self.easeInOut(Self.progress(time, 0.15, 0.45))
        return ZStack {
            Color.black
            mark.resizable().frame(width: Self.size, height: Self.size)
        }
        .opacity(fade)
        .allowsHitTesting(fade > 0.5)
    }

    // MARK: Full motion

    private func full(in size: CGSize) -> some View {
        let launched = time >= 0.40
        let flight = Self.easeIn(Self.progress(time, 0.40, 1.15))
        let swell = Self.easeInOut(Self.progress(time, 0.50, 1.15))
        let open = Self.easeInOut(Self.progress(time, 0.70, 1.40))
        let route = Self.route(in: size)
        let jet = Self.pose(on: route, at: flight)

        return ZStack {
            Color.black.opacity(1 - open)

            // The tile: the launch mark as is until lift off, then the bare tile under a fading copy of the mark
            // (so the jet's old place empties softly while the jet itself, lifted out, starts to move).
            Group {
                if launched {
                    emptyTile.overlay {
                        mark.resizable().frame(width: Self.size, height: Self.size)
                            .opacity(1 - Self.progress(time, 0.40, 0.52))
                    }
                } else {
                    mark.resizable().frame(width: Self.size, height: Self.size)
                }
            }
            // The glint keeps to the mark's own pixels (no clip shape, so the first frame's edges are the mark's).
            .overlay { glint.mask { mark.resizable().frame(width: Self.size, height: Self.size) } }
            .scaleEffect(1 + 0.6 * swell)
            .blur(radius: 6 * swell)
            .opacity(1 - Self.easeIn(swell))
            .position(x: size.width / 2, y: size.height / 2)

            if launched {
                contrail(route, upTo: flight)
                    .opacity(1 - open)

                jetAlone
                    .rotation3DEffect(.degrees(-16 * sin(.pi * min(1, flight * 1.4))),
                                      axis: (x: 1, y: 0.35, z: 0), perspective: 0.4)
                    .rotationEffect(jet.turn)
                    .scaleEffect(1 + 0.5 * flight)
                    .position(jet.point)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(open < 0.3)
    }

    /// A soft band of light, tilted like the jet's climb, moving from the lower left to the upper right.
    private var glint: some View {
        let g = -0.3 + 1.6 * Self.easeInOut(Self.progress(time, 0.06, 0.56))
        return LinearGradient(stops: [.init(color: .white.opacity(0), location: 0.40),
                                      .init(color: .white.opacity(0.5), location: 0.5),
                                      .init(color: .white.opacity(0), location: 0.60)],
                              startPoint: UnitPoint(x: g - 0.5, y: 1.5 - g),
                              endPoint: UnitPoint(x: g + 0.5, y: 0.5 - g))
            .blendMode(.plusLighter)
            .opacity(time < 0.6 ? 1 : 0)
    }

    /// The jet's light pixels, as a mask: the dark tile goes fully clear, the white airframe fully opaque.
    private var jetMask: some View {
        mark.resizable().frame(width: Self.size, height: Self.size)
            .brightness(-0.1)
            .contrast(2.4)
            .luminanceToAlpha()
    }

    /// The jet on its own, its real pixels lifted out of the tile.
    private var jetAlone: some View {
        mark.resizable().frame(width: Self.size, height: Self.size)
            .mask { jetMask }
    }

    /// The tile without the jet: its squircle and its top to bottom gradient.
    private var emptyTile: some View {
        RoundedRectangle(cornerRadius: Self.size * 0.225, style: .continuous)
            .fill(LinearGradient(stops: [.init(color: Self.tileTop, location: 0),
                                         .init(color: Self.tileMiddle, location: 0.5),
                                         .init(color: Self.tileBottom, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: Self.size, height: Self.size)
    }

    /// The contrail: drawn up to the jet (hidden under its body) and thinning away from where it started.
    private func contrail(_ route: Path, upTo flight: Double) -> some View {
        let head = CGFloat(flight)
        let tail = max(0, head - 0.5)
        let trail = route.trimmedPath(from: tail, to: head)
        return ZStack {
            trail.stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .blur(radius: 6)
            trail.stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .blur(radius: 0.8)
        }
        .mask {
            // Fades toward the old end so the trail reads as dissipating, not as a drawn line.
            trail.stroke(LinearGradient(colors: [.clear, .white],
                                        startPoint: UnitPoint(x: 0, y: 1), endPoint: UnitPoint(x: 1, y: 0)),
                         style: StrokeStyle(lineWidth: 24, lineCap: .round))
        }
    }

    // MARK: Route

    /// The climb: from the tile's centre, out along the jet's heading, curving up and off the upper right.
    static func route(in size: CGSize) -> Path {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let w = size.width, h = size.height
        var path = Path()
        path.move(to: c)
        path.addCurve(to: CGPoint(x: c.x + 0.78 * w, y: c.y - 0.66 * h),
                      control1: CGPoint(x: c.x + 0.24 * w, y: c.y - 0.05 * h),
                      control2: CGPoint(x: c.x + 0.44 * w, y: c.y - 0.2 * h))
        return path
    }

    /// Where the jet is at `flight` (0 to 1 of the route's length) and how far it has turned from its start.
    static func pose(on route: Path, at flight: Double) -> (point: CGPoint, turn: Angle) {
        let f = CGFloat(min(max(flight, 0), 1))
        let start = route.trimmedPath(from: 0, to: 0.001).currentPoint ?? .zero
        let first = route.trimmedPath(from: 0, to: 0.02).currentPoint ?? .zero
        let here = f <= 0.001 ? start : (route.trimmedPath(from: 0, to: f).currentPoint ?? start)
        let behind = route.trimmedPath(from: 0, to: max(0.001, f - 0.02)).currentPoint ?? start
        let ahead = f < 0.03 ? first : here
        let back = f < 0.03 ? start : behind
        let initial = atan2(first.y - start.y, first.x - start.x)
        let now = atan2(ahead.y - back.y, ahead.x - back.x)
        return (here, .radians(now - initial))
    }

    // MARK: Easing

    static func progress(_ t: Double, _ from: Double, _ to: Double) -> Double {
        min(max((t - from) / (to - from), 0), 1)
    }

    static func easeInOut(_ p: Double) -> Double { p * p * (3 - 2 * p) }

    /// A take off: gentle at first, then quicker and quicker.
    static func easeIn(_ p: Double) -> Double { p * p * (0.4 + 0.6 * p) }
}

#Preview("Splash, scrub") {
    @Previewable @State var t = 0.0
    VStack(spacing: 0) {
        SplashFrame(mark: Image("LaunchMark"), time: t, reduceMotion: false)
            .background(Color.blue.opacity(0.3))
        Slider(value: $t, in: 0...1.45).padding()
    }
}
