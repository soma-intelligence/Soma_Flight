import SwiftUI

/// The drawing a pull to refresh shows above a list. One is picked at random for each pull (owner's call,
/// 2026-11-08): the jet of the app icon, or a departure board settling on the traveller's airports.
enum PullRefreshStyle: CaseIterable {
    /// The icon's white jet flies in from far away, hangs with two contrails while loading, climbs out.
    case jet
    /// Three split-flap tiles flip through letters and settle on the traveller's airports.
    case board
}

/// Where a pull to refresh stands.
enum PullRefreshPhase: Equatable {
    /// The list is pulled down: `progress` runs 0 to 1, 1 at the release threshold.
    case pulling(progress: CGFloat)
    /// Released past the threshold: the screen reloads.
    case refreshing(since: Date)
    /// The reload is over: the drawing leaves before the list goes back up. `refreshed` is when the
    /// reload began, so the board's flips carry on where they were.
    case finishing(since: Date, refreshed: Date)
}

extension EnvironmentValues {
    /// The airports the departure board settles on, as IATA codes, first the one the traveller flies to
    /// next. Empty falls back to `PullRefreshBoard.fallback`.
    @Entry public var refreshAirports: [String] = []
}

public extension HomeModel {
    /// The departure board's airports: where the traveller flies next (followed flights, soonest first),
    /// then the airports of their history, most used first, then their saved airports. Three-letter IATA
    /// codes only, each once, six at most.
    var refreshAirports: [String] {
        let lookup = env.lookup
        func iata(_ code: String) -> String? {
            if code.count == 3 { return code.uppercased() }
            return lookup(code)?.iata
        }
        let next = (myFlights.live + myFlights.upcoming).map { $0.destinationIata ?? $0.destinationIcao }
        var counts: [String: Int] = [:]
        for f in passport.allFlights {
            counts[f.originIcao, default: 0] += 1
            counts[f.destinationIcao, default: 0] += 1
        }
        let used = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        var seen = Set<String>(), out: [String] = []
        for code in next + used + airportsList.favorites.codes {
            guard let c = iata(code), c.count == 3, seen.insert(c).inserted else { continue }
            out.append(c)
            if out.count == 6 { break }
        }
        return out
    }
}

/// The band drawn above a list being pulled or refreshing: `PullRefreshStyle`'s drawing, `height` tall,
/// anchored at its top so a short pull shows only its top part.
struct PullRefreshHeader: View {
    static let height: CGFloat = 110

    var style: PullRefreshStyle
    var phase: PullRefreshPhase

    var body: some View {
        switch style {
        case .jet: PullRefreshJet(phase: phase)
        case .board: PullRefreshBoard(phase: phase)
        }
    }
}

// MARK: - Timing

/// Shared easing for the two drawings.
enum PullRefreshCurve {
    static func clamp(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
    static func out(_ k: CGFloat) -> CGFloat { 1 - pow(1 - k, 3) }
    static func inOut(_ k: CGFloat) -> CGFloat { k < 0.5 ? 4 * k * k * k : 1 - pow(-2 * k + 2, 3) / 2 }
}

/// How long the finishing drawing plays before the list goes back up.
let pullRefreshFinish: Duration = .milliseconds(800)

// MARK: - Jet

/// The icon's white jet (`empty-jet-climb`). Pulling brings it in from small and low left to full size in
/// the middle; while loading it hangs in the air, banking a little, two contrails streaming from behind its
/// engines and faint air streaks passing; when done it climbs out to the top right. Reduce Motion fades it.
struct PullRefreshJet: View {
    var phase: PullRefreshPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animating: Bool { if case .pulling = phase { false } else { true } }

    var body: some View {
        TimelineView(.animation(paused: !animating)) { timeline in
            Canvas { ctx, size in draw(&ctx, size, now: timeline.date) }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, now: Date) {
        typealias C = PullRefreshCurve
        let image = ctx.resolve(Image("empty-jet-climb", bundle: .module))
        let ratio = image.size.width > 0 ? image.size.height / image.size.width : 0.4756
        let baseWidth: CGFloat = 132, cx = size.width / 2 + 4, cy = size.height * 0.5
        var x = cx, y = cy, scale: CGFloat = 1, angle: CGFloat = 0, alpha: CGFloat = 1, leave: CGFloat = 0
        var trails = false, t: CGFloat = 0
        switch phase {
        case .pulling(let k):
            let a = reduceMotion ? 1 : C.out(C.clamp(k))
            x = cx - (1 - a) * 46; y = cy + (1 - a) * 26; scale = 0.22 + 0.78 * a; angle = (1 - a) * -0.14
            alpha = C.clamp(k * 1.8)
        case .refreshing(let since):
            t = CGFloat(now.timeIntervalSince(since))
            if !reduceMotion {
                x = cx + sin(t * 1.6) * 2; y = cy + sin(t * 2.1) * 2.6; angle = sin(t * 1.3) * 0.026; trails = true
            }
        case .finishing(let since, let refreshed):
            let s = CGFloat(now.timeIntervalSince(since))
            t = CGFloat(now.timeIntervalSince(refreshed))
            if reduceMotion { alpha = 1 - C.clamp(s / 0.8) } else {
                leave = C.inOut(C.clamp(s / 0.8))
                x = cx + leave * size.width * 0.75; y = cy - leave * size.height * 1.05
                scale = 1 + leave * 0.35; angle = -leave * 0.06; alpha = 1 - C.clamp((s - 0.55) / 0.3); trails = true
            }
        }
        let w = baseWidth * scale, h = w * ratio
        if trails {
            // Contrails from behind the two engines (where the asset draws their exhausts), down and to the
            // left, opposite the heading.
            let len = 90 + leave * 120, ux: CGFloat = -0.894, uy: CGFloat = 0.447
            for (ex, ey) in [(0.36, 0.25), (0.33, 0.43)] as [(CGFloat, CGFloat)] {
                let s = CGPoint(x: x - w / 2 + ex * w, y: y - h / 2 + ey * h)
                let e = CGPoint(x: s.x + ux * len, y: s.y + uy * len)
                var p = Path(); p.move(to: s); p.addLine(to: e)
                ctx.stroke(p, with: .linearGradient(Gradient(colors: [.white.opacity(0.5 * alpha), .white.opacity(0)]),
                                                     startPoint: s, endPoint: e),
                           style: StrokeStyle(lineWidth: 2.2 * scale, lineCap: .round))
            }
            // Faint air streaks passing by.
            for i in 0..<6 {
                let p = (t * 0.9 + CGFloat(i) / 6).truncatingRemainder(dividingBy: 1)
                let ox = size.width * (0.95 - p * 1.1) + CGFloat(i * 37 % 60)
                let oy = size.height * (0.05 + (CGFloat(i) * 0.17).truncatingRemainder(dividingBy: 1)) + p * 40
                var s = Path(); s.move(to: CGPoint(x: ox, y: oy)); s.addLine(to: CGPoint(x: ox - 16, y: oy + 8))
                ctx.stroke(s, with: .color(.white.opacity(0.18 * sin(p * .pi) * alpha)),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
        }
        ctx.drawLayer { layer in
            layer.opacity = alpha
            layer.addFilter(.shadow(color: .black.opacity(0.55), radius: 7 * scale, y: 6 * scale))
            layer.translateBy(x: x, y: y)
            layer.rotate(by: .radians(angle))
            layer.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        }
    }
}

// MARK: - Departure board

/// Three split-flap tiles. They drop in as the list is pulled, showing dashes; while loading they flip
/// through letters and settle on the first airport, then the next one every 1.25 s; when done they fade.
/// Reduce Motion shows the airport without the flips.
struct PullRefreshBoard: View {
    var phase: PullRefreshPhase
    @Environment(\.refreshAirports) private var airports
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Big hubs, when the traveller has no airport yet.
    static let fallback = ["SFO", "CDG", "JFK"]
    private static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let cycle: CGFloat = 1.25

    private var codes: [String] { airports.isEmpty ? Self.fallback : airports }
    private var animating: Bool { if case .pulling = phase { false } else { true } }

    var body: some View {
        TimelineView(.animation(paused: !animating)) { timeline in
            Canvas { ctx, size in draw(&ctx, size, now: timeline.date) }
        }
        .accessibilityHidden(true)
    }

    /// The tiles' letters at `elapsed` seconds into loading: the code shown, the one coming, and the flip's
    /// progress (0 when still).
    private func letters(_ i: Int, elapsed t: CGFloat) -> (Character, Character, CGFloat) {
        let dash: Character = "-"
        let n = Int(t / Self.cycle), local = t - CGFloat(n) * Self.cycle
        let to = Array(codes[n % codes.count])[i]
        let from: Character = n == 0 ? dash : Array(codes[(n - 1) % codes.count])[i]
        if reduceMotion { return (to, to, 0) }
        let start = 0.1 + CGFloat(i) * 0.12, steps = 4, stepT: CGFloat = 0.09, u = local - start
        guard u > 0 else { return (from, from, 0) }
        guard u < CGFloat(steps) * stepT else { return (to, to, 0) }
        let st = Int(u / stepT), p = (u - CGFloat(st) * stepT) / stepT
        func shift(_ c: Character, _ by: Int) -> Character {
            let base = Self.letters.firstIndex(of: c) ?? 0
            return Self.letters[(base + by) % 26]
        }
        let seq: [Character] = [from, shift(from, 7 + i), shift(from, 13 + i), shift(to, 21), to]
        return (seq[st], seq[st + 1], p)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, now: Date) {
        typealias C = PullRefreshCurve
        let tw: CGFloat = 34, th: CGFloat = 46, gap: CGFloat = 6
        let x0 = size.width / 2 - (3 * tw + 2 * gap) / 2, y0 = size.height * 0.5 - th / 2 + 4
        var appear: CGFloat = 1, elapsed: CGFloat? = nil
        switch phase {
        case .pulling(let k): appear = C.clamp(k)
        case .refreshing(let since): elapsed = CGFloat(now.timeIntervalSince(since))
        case .finishing(let since, let refreshed):
            let s = CGFloat(now.timeIntervalSince(since))
            appear = 1 - C.clamp((s - 0.35) / 0.45)
            // The flip under way finishes, then the board holds that airport while it fades.
            let n = (CGFloat(since.timeIntervalSince(refreshed)) / Self.cycle).rounded(.down)
            elapsed = min(CGFloat(now.timeIntervalSince(refreshed)), n * Self.cycle + 0.75)
        }
        for i in 0..<3 {
            let ap = C.clamp(appear * 3 - CGFloat(i) * 0.9)
            guard ap > 0 else { continue }
            let x = x0 + CGFloat(i) * (tw + gap), y = y0 - (1 - C.out(ap)) * 14
            var (a, b, p): (Character, Character, CGFloat) = ("-", "-", 0)
            if let elapsed { (a, b, p) = letters(i, elapsed: elapsed) }
            var tile = ctx
            tile.opacity = ap
            drawTile(&tile, CGRect(x: x, y: y, width: tw, height: th), a, b, p)
        }
    }

    private func drawTile(_ ctx: inout GraphicsContext, _ r: CGRect, _ a: Character, _ b: Character, _ p: CGFloat) {
        let half = r.height / 2
        let top = CGRect(x: r.minX, y: r.minY, width: r.width, height: half)
        let bottom = CGRect(x: r.minX, y: r.midY, width: r.width, height: half)
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous).path(in: r)
        func face(_ ch: Character, _ upper: Bool, _ c: inout GraphicsContext) {
            var f = c
            f.clip(to: Path(upper ? top : bottom))
            f.fill(shape, with: .color(upper ? Color(white: 0.137) : Color(white: 0.118)))
            f.draw(Text(String(ch)).font(.system(size: 29, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(white: 0.95)),
                   at: CGPoint(x: r.midX, y: r.midY + 1), anchor: .center)
        }
        face(b, true, &ctx)
        face(a, false, &ctx)
        if p > 0 {
            // The falling flap: the old top folds down to the hinge, then the new bottom unfolds from it,
            // darkening as it turns.
            var flap = ctx
            let s = p < 0.5 ? 1 - p * 2 : (p - 0.5) * 2
            flap.translateBy(x: 0, y: r.midY); flap.scaleBy(x: 1, y: max(0.001, s)); flap.translateBy(x: 0, y: -r.midY)
            face(p < 0.5 ? a : b, p < 0.5, &flap)
            flap.fill(Path(p < 0.5 ? top : bottom), with: .color(.black.opacity(0.45 * (p < 0.5 ? p * 2 : (1 - p) * 2))))
        } else {
            face(a, true, &ctx)
        }
        ctx.fill(Path(CGRect(x: r.minX, y: r.midY - 0.5, width: r.width, height: 1)), with: .color(Color(white: 0.047)))
        ctx.fill(Path(CGRect(x: r.minX + 4, y: r.minY + 0.5, width: r.width - 8, height: 1)), with: .color(.white.opacity(0.06)))
    }
}

// MARK: - Scroll view

#if os(iOS)
/// A scroll view with the app's own pull to refresh in place of the system spinner: pulling past
/// `threshold` and letting go reloads, the list holding `PullRefreshHeader.height` open above its first row
/// while the drawing plays, then the drawing leaves and the list springs back up. Each pull draws one of the
/// `PullRefreshStyle`s at random.
struct PullRefreshScroll<Content: View>: View {
    var refresh: () async -> Void
    @ViewBuilder var content: Content

    static var threshold: CGFloat { 96 }
    /// The least time the drawing stays, so a fast reload still shows the board settle on an airport.
    static var minimum: Duration { .milliseconds(1200) }

    @State private var pull: CGFloat = 0
    @State private var hold: CGFloat = 0
    @State private var phase: PullRefreshPhase = .pulling(progress: 0)
    @State private var style: PullRefreshStyle = .jet
    @State private var dragging = false
    @State private var busy = false

    private var armed: Bool { !busy && pull >= Self.threshold }

    var body: some View {
        ScrollView {
            content.padding(.top, hold)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            max(0, -(geo.contentOffset.y + geo.contentInsets.top))
        } action: { _, now in
            pull = now
            if !busy {
                if now > 0, case .pulling(let k) = phase, k == 0 { style = PullRefreshStyle.allCases.randomElement() ?? .jet }
                phase = .pulling(progress: min(1.2, now / Self.threshold))
            }
        }
        .onScrollPhaseChange { old, new in
            dragging = new == .interacting
            if old == .interacting, new != .interacting, armed { start() }
        }
        .background(alignment: .top) {
            if pull > 0 || hold > 0 {
                PullRefreshHeader(style: style, phase: phase)
                    .frame(height: PullRefreshHeader.height)
                    .frame(maxWidth: .infinity)
                    .mask(alignment: .top) {
                        Rectangle().frame(height: max(pull, hold) + 1)
                    }
                    .allowsHitTesting(false)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: armed) { _, now in now }
    }

    private func start() {
        busy = true
        let began = Date()
        phase = .refreshing(since: began)
        withAnimation(.spring(duration: 0.35, bounce: 0)) { hold = PullRefreshHeader.height }
        Task { @MainActor in
            let clock = ContinuousClock(), t0 = clock.now
            await refresh()
            let left = Self.minimum - (clock.now - t0)
            if left > .zero { try? await Task.sleep(for: left) }
            phase = .finishing(since: Date(), refreshed: began)
            try? await Task.sleep(for: pullRefreshFinish)
            withAnimation(.spring(duration: 0.45, bounce: 0)) { hold = 0 }
            try? await Task.sleep(for: .milliseconds(450))
            phase = .pulling(progress: 0)
            busy = false
        }
    }
}
#endif
