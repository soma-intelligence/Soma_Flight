import SwiftUI

/// The sky behind the plane on the "Where is my plane?" card, after the light where the plane is
/// (`SkyPhase`): a deep night with a few twinkling stars and a faint moon glow, a warm dawn or dusk with the
/// last stars fading out, a soft blue day with a few clouds drifting by. Our own colours in both
/// appearances (the card stays dark), every position seeded so the same plane always gets the same sky,
/// and still under Reduce Motion. The top darkens under the title and the bottom melts into the card.
struct PlaneSky: View {
    var phase: SkyPhase
    /// Seeds the stars and clouds (`PlaneSky.seed`), so a tail keeps its sky from one visit to the next.
    var seed: UInt64

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    /// Ticks for the twinkle and the drift: slow movements, so 20 frames a second is plenty.
    static let frameInterval: TimeInterval = 1.0 / 20

    var body: some View {
        ZStack {
            LinearGradient(stops: Self.gradient(phase), startPoint: .top, endPoint: .bottom)
            if reduceMotion {
                layer(t: 0)
            } else {
                TimelineView(.animation(minimumInterval: Self.frameInterval)) { context in
                    layer(t: context.date.timeIntervalSince(start))
                }
            }
            // A dark scrim under the title and the aircraft's name keeps the white words readable on any sky.
            LinearGradient(stops: [.init(color: Self.scrim.opacity(0.78), location: 0),
                                   .init(color: Self.scrim.opacity(0.35), location: 0.28),
                                   .init(color: .clear, location: 0.5)],
                           startPoint: .top, endPoint: .bottom)
        }
        // Fades out at the bottom, so the sky melts into the card behind the list of flights.
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.72),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func layer(t: TimeInterval) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            Self.draw(phase: phase, seed: seed, t: t, in: &context, size: size)
        }
    }

    // MARK: - Palette

    static let scrim = Color(red: 0.04, green: 0.05, blue: 0.11)

    /// Top to bottom. The day stays a deep enough blue for white words; dawn and dusk warm the horizon.
    static func gradient(_ phase: SkyPhase) -> [Gradient.Stop] {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        return switch phase {
        case .night: [.init(color: c(0.02, 0.04, 0.10), location: 0), .init(color: c(0.05, 0.08, 0.18), location: 0.6),
                      .init(color: c(0.09, 0.12, 0.24), location: 1)]
        case .dawn: [.init(color: c(0.10, 0.14, 0.30), location: 0), .init(color: c(0.42, 0.38, 0.56), location: 0.55),
                     .init(color: c(0.90, 0.62, 0.50), location: 1)]
        case .day: [.init(color: c(0.14, 0.33, 0.62), location: 0), .init(color: c(0.30, 0.54, 0.82), location: 0.6),
                    .init(color: c(0.52, 0.71, 0.90), location: 1)]
        case .dusk: [.init(color: c(0.09, 0.10, 0.26), location: 0), .init(color: c(0.40, 0.26, 0.44), location: 0.55),
                     .init(color: c(0.92, 0.50, 0.32), location: 1)]
        }
    }

    // MARK: - Drawing

    struct Star { var x, y, radius, brightness, speed, offset: Double }
    struct Cloud { var x, y, width, speed: Double; var puffs: [(dx: Double, dy: Double, r: Double)] }

    /// FNV-1a of the tail (or the flight number): stable across launches, unlike `hashValue`.
    static func seed(_ text: String) -> UInt64 {
        text.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
    }

    /// SplitMix64: a small, seeded, platform-independent generator.
    struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
        mutating func next(_ range: ClosedRange<Double>) -> Double { range.lowerBound + next() * (range.upperBound - range.lowerBound) }
    }

    /// The stars, in unit coordinates, thicker towards the top of the sky but kept under the title and the
    /// aircraft's name, where a star would read as a stray dot in the words.
    static func stars(seed: UInt64, count: Int = 46) -> [Star] {
        var rng = Rng(state: seed)
        return (0..<count).map { _ in
            Star(x: rng.next(), y: 0.4 + pow(rng.next(), 1.4) * 0.5, radius: rng.next(0.45...1.25),
                 brightness: rng.next(0.35...0.95), speed: rng.next(0.5...1.6), offset: rng.next(0...(2 * .pi)))
        }
    }

    /// The clouds, in unit coordinates, each a few overlapping puffs.
    static func clouds(seed: UInt64, count: Int = 4) -> [Cloud] {
        var rng = Rng(state: seed ^ 0x5bd1_e995)
        return (0..<count).map { i in
            let puffs = (0..<4).map { _ in (dx: rng.next(-0.5...0.5), dy: rng.next(-0.18...0.12), r: rng.next(0.22...0.42)) }
            return Cloud(x: (Double(i) + rng.next(0...0.6)) / Double(count), y: rng.next(0.12...0.62),
                         width: rng.next(0.22...0.38), speed: rng.next(2.5...5.5), puffs: puffs)
        }
    }

    static func draw(phase: SkyPhase, seed: UInt64, t: TimeInterval, in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }

        if phase == .night {
            // A faint moon glow high on the right, and a pale disc inside it.
            let moon = CGPoint(x: w * 0.84, y: h * 0.2)
            let glow = min(w, h) * 0.5
            context.fill(Path(ellipseIn: CGRect(x: moon.x - glow, y: moon.y - glow, width: glow * 2, height: glow * 2)),
                         with: .radialGradient(Gradient(colors: [.white.opacity(0.13), .white.opacity(0.04), .clear]),
                                               center: moon, startRadius: 0, endRadius: glow))
            context.drawLayer { disc in
                disc.addFilter(.blur(radius: 1.2))
                disc.fill(Path(ellipseIn: CGRect(x: moon.x - 7, y: moon.y - 7, width: 14, height: 14)),
                          with: .color(Color(red: 0.95, green: 0.95, blue: 0.88).opacity(0.5)))
            }
        }

        // Stars: all of them at night, the brightest few fading at dawn and dusk, none by day.
        let starLevel: Double = switch phase { case .night: 1; case .dawn, .dusk: 0.4; case .day: 0 }
        if starLevel > 0 {
            for (i, star) in stars(seed: seed).enumerated() {
                if phase != .night, star.brightness < 0.7 || star.y > 0.6 { continue }
                let twinkle = 0.7 + 0.3 * sin(t * star.speed + star.offset)
                let alpha = star.brightness * twinkle * starLevel
                let r = star.radius
                let rect = CGRect(x: star.x * w - r, y: star.y * h - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(alpha)))
                // Every seventh star a little brighter, with a soft halo.
                if i % 7 == 0 {
                    let halo = rect.insetBy(dx: -r * 2.5, dy: -r * 2.5)
                    context.fill(Path(ellipseIn: halo),
                                 with: .radialGradient(Gradient(colors: [.white.opacity(alpha * 0.35), .clear]),
                                                       center: CGPoint(x: halo.midX, y: halo.midY),
                                                       startRadius: 0, endRadius: halo.width / 2))
                }
            }
        }

        // Clouds: soft and white by day, a thin warm wisp at dawn and dusk, none at night.
        let cloudColor: Color? = switch phase {
        case .day: .white.opacity(0.22)
        case .dawn, .dusk: Color(red: 1, green: 0.78, blue: 0.7).opacity(0.12)
        case .night: nil
        }
        if let cloudColor {
            let list = clouds(seed: seed)
            context.drawLayer { sky in
                sky.addFilter(.blur(radius: 10))
                for (i, cloud) in list.enumerated() where phase == .day || i % 2 == 0 {
                    let cw = cloud.width * w
                    let span = w + cw * 2
                    let x = (cloud.x * span + t * cloud.speed).truncatingRemainder(dividingBy: span) - cw
                    let y = cloud.y * h
                    for puff in cloud.puffs {
                        let r = puff.r * cw
                        sky.fill(Path(ellipseIn: CGRect(x: x + puff.dx * cw - r, y: y + puff.dy * cw - r * 0.6,
                                                        width: r * 2, height: r * 1.2)),
                                 with: .color(cloudColor))
                    }
                }
            }
        }
    }
}
