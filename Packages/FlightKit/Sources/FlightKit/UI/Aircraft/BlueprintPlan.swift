import SwiftUI

// MARK: - Geometry

/// A trapezoidal surface (wing or tailplane) in plan, in metres: the leading edge from the apex on the
/// centreline, swept back to the tip; the trailing edge from the root, through an optional kink, to the tip.
struct Planform: Sendable, Equatable {
    /// Leading edge on the centreline, metres aft of the nose tip.
    var apex: Double
    var rootChord: Double
    /// Tip to tip.
    var span: Double
    var tipChord: Double
    /// Leading edge sweep, degrees.
    var sweep: Double
    /// Trailing edge kink (half-span station and chord there), the A320 or 777 "yehudi".
    var kink: (y: Double, chord: Double)?

    static func == (a: Planform, b: Planform) -> Bool {
        a.apex == b.apex && a.rootChord == b.rootChord && a.span == b.span && a.tipChord == b.tipChord
            && a.sweep == b.sweep && a.kink?.y == b.kink?.y && a.kink?.chord == b.kink?.chord
    }

    func leadingEdge(_ y: Double) -> Double { apex + y * tan(sweep * .pi / 180) }

    func trailingEdge(_ y: Double) -> Double {
        let half = span / 2
        let rootTE = apex + rootChord, tipTE = leadingEdge(half) + tipChord
        if let k = kink {
            let kinkTE = leadingEdge(k.y) + k.chord
            return y <= k.y ? rootTE + (kinkTE - rootTE) * y / k.y : kinkTE + (tipTE - kinkTE) * (y - k.y) / (half - k.y)
        }
        return rootTE + (tipTE - rootTE) * y / half
    }

    func chord(_ y: Double) -> Double { trailingEdge(y) - leadingEdge(y) }

    /// The outline of one side (y > 0) from `fromY` outboard, clockwise: leading edge out, tip, trailing edge in.
    func half(from fromY: Double) -> [CGPoint] {
        var te: [Double] = [span / 2]
        if let k = kink, k.y > fromY { te.append(k.y) }
        te.append(fromY)
        return [CGPoint(x: leadingEdge(fromY), y: fromY), CGPoint(x: leadingEdge(span / 2), y: span / 2)]
            + te.map { CGPoint(x: trailingEdge($0), y: $0) }
    }
}

/// An engine nacelle in plan: the inlet's station, its length and width, its centre off the centreline.
struct Nacelle: Sendable, Equatable {
    var y: Double
    var x: Double
    var length: Double
    var width: Double
    /// Hung from the rear fuselage on a stub (CRJ), not from the wing.
    var rear = false
    /// Propeller diameter for a turboprop, 0 for a jet.
    var prop: Double = 0
}

/// The families the plan draws, each from one representative type's published airport-planning
/// dimensions: A320neo and 737 MAX 8 for the narrowbody twin, 787-9 / A350-900 for the widebody twin,
/// A380-800 for the four-engine widebody, E190 for the regional jet, CRJ900 for the rear-engine jet and
/// ATR 72-600 for the turboprop.
enum PlanFamily: String, CaseIterable, Sendable {
    case narrow, wideTwin, wideQuad, regional, rearJet, turboprop

    init(_ family: AircraftFamily?) {
        switch family {
        case .a330, .a350, .b767, .b777, .b787: self = .wideTwin
        case .a380, .b747: self = .wideQuad
        case .ejet, .a220: self = .regional
        case .crj: self = .rearJet
        case .atr: self = .turboprop
        default: self = .narrow
        }
    }

    /// "Narrowbody twin", for the drawing's title block.
    var title: String {
        switch self {
        case .narrow: "Narrowbody twin"
        case .wideTwin: "Widebody twin"
        case .wideQuad: "Widebody, four engines"
        case .regional: "Regional jet"
        case .rearJet: "Regional jet, rear engines"
        case .turboprop: "Turboprop"
        }
    }

    var plan: PlanGeometry {
        switch self {
        case .narrow:
            // A320neo / 737 MAX 8: 37.6 m long, 3.95 m wide, 35.8 m span, 25 deg quarter chord sweep.
            PlanGeometry(
                length: 37.57, width: 3.95, noseLength: 4.6, tailLength: 9.6, tailWidth: 0.55,
                wing: Planform(apex: 11.6, rootChord: 7.1, span: 35.8, tipChord: 1.5, sweep: 27.5, kink: (6.3, 4.6)),
                stab: Planform(apex: 31.0, rootChord: 3.9, span: 12.45, tipChord: 1.3, sweep: 34),
                engines: [Nacelle(y: 5.75, x: 9.6, length: 6.2, width: 2.3)],
                fin: (30.2, 7.0, 0.45), doors: [3.2, 32.4], exits: [13.6, 14.5],
                windows: (5.4, 31.2, 0.53), highWing: false, tTail: false, layout: [3, 3])
        case .wideTwin:
            // 787-9 / A350-900: 63 m long, 5.8 m wide, 60 m span, 32 deg leading edge.
            PlanGeometry(
                length: 62.8, width: 5.77, noseLength: 7.0, tailLength: 15.0, tailWidth: 0.8,
                wing: Planform(apex: 22.0, rootChord: 13.0, span: 60.1, tipChord: 2.4, sweep: 33, kink: (9.8, 7.4)),
                stab: Planform(apex: 51.6, rootChord: 6.6, span: 19.8, tipChord: 1.9, sweep: 37),
                engines: [Nacelle(y: 9.8, x: 21.4, length: 9.0, width: 3.6)],
                fin: (50.0, 11.5, 0.6), doors: [5.2, 15.8, 34.6, 53.2], exits: [],
                windows: (7.2, 53.0, 0.62), highWing: false, tTail: false, layout: [3, 3, 3])
        case .wideQuad:
            // A380-800: 72.7 m long, 7.1 m wide, 79.8 m span.
            PlanGeometry(
                length: 72.7, width: 7.14, noseLength: 8.6, tailLength: 17.0, tailWidth: 1.0,
                wing: Planform(apex: 25.0, rootChord: 18.0, span: 79.75, tipChord: 4.0, sweep: 33.5, kink: (12.5, 11.5)),
                stab: Planform(apex: 59.5, rootChord: 10.5, span: 30.4, tipChord: 3.2, sweep: 37),
                engines: [Nacelle(y: 15.6, x: 29.6, length: 8.4, width: 3.6), Nacelle(y: 25.7, x: 36.0, length: 8.4, width: 3.4)],
                fin: (57.5, 14.0, 0.75), doors: [6.4, 18.2, 39.8, 50.4, 61.8], exits: [],
                windows: (8.0, 63.0, 0.66), highWing: false, tTail: false, layout: [3, 4, 3])
        case .regional:
            // E190: 36.2 m long, 3.0 m wide, 28.7 m span.
            PlanGeometry(
                length: 36.24, width: 3.01, noseLength: 3.7, tailLength: 8.4, tailWidth: 0.45,
                wing: Planform(apex: 13.2, rootChord: 6.0, span: 28.72, tipChord: 1.3, sweep: 26, kink: (4.6, 3.9)),
                stab: Planform(apex: 30.6, rootChord: 3.3, span: 12.08, tipChord: 1.2, sweep: 31),
                engines: [Nacelle(y: 4.6, x: 11.6, length: 5.2, width: 1.95)],
                fin: (29.0, 7.0, 0.38), doors: [3.0, 31.0], exits: [15.0],
                windows: (4.6, 30.6, 0.56), highWing: false, tTail: false, layout: [2, 2])
        case .rearJet:
            // CRJ900: 36.2 m long, 2.7 m wide, 24.9 m span, engines on the rear fuselage, T-tail.
            PlanGeometry(
                length: 36.2, width: 2.69, noseLength: 3.5, tailLength: 7.8, tailWidth: 0.4,
                wing: Planform(apex: 14.6, rootChord: 5.4, span: 24.85, tipChord: 1.2, sweep: 27, kink: (3.6, 3.6)),
                stab: Planform(apex: 33.0, rootChord: 2.6, span: 8.54, tipChord: 1.3, sweep: 32),
                engines: [Nacelle(y: 2.75, x: 26.4, length: 4.4, width: 1.6, rear: true)],
                fin: (30.4, 5.2, 0.36), doors: [2.9, 28.0], exits: [16.2],
                windows: (4.4, 27.6, 0.52), highWing: false, tTail: true, layout: [2, 2])
        case .turboprop:
            // ATR 72-600: 27.2 m long, 2.9 m wide, 27.1 m span, high straight wing, T-tail, 3.9 m props.
            PlanGeometry(
                length: 27.17, width: 2.87, noseLength: 3.0, tailLength: 7.0, tailWidth: 0.4,
                wing: Planform(apex: 10.9, rootChord: 2.57, span: 27.05, tipChord: 1.59, sweep: 3, kink: (4.1, 2.57)),
                stab: Planform(apex: 25.0, rootChord: 1.9, span: 7.31, tipChord: 1.15, sweep: 8),
                engines: [Nacelle(y: 4.1, x: 9.1, length: 6.6, width: 1.25, prop: 3.93)],
                fin: (22.0, 4.6, 0.32), doors: [2.6, 22.6], exits: [],
                windows: (4.2, 22.0, 0.76), highWing: true, tTail: true, layout: [2, 2])
        }
    }
}

/// A family's plan view in metres, x aft from the nose tip, y outboard from the centreline.
struct PlanGeometry: Sendable {
    var length: Double
    var width: Double
    /// From the nose tip to the full barrel width.
    var noseLength: Double
    /// From the end of the barrel to the tail cone's end.
    var tailLength: Double
    /// Across the tail cone's end (APU exhaust).
    var tailWidth: Double
    var wing: Planform
    var stab: Planform
    /// One side's engines (mirrored).
    var engines: [Nacelle]
    /// Fin root in plan: leading edge station, length, thickness.
    var fin: (x: Double, length: Double, thickness: Double)
    /// Passenger door stations (a door is 1 m long).
    var doors: [Double]
    /// Overwing exit stations (0.6 m).
    var exits: [Double]
    /// Window row: first and last station, pitch.
    var windows: (from: Double, to: Double, pitch: Double)
    var highWing: Bool
    var tTail: Bool
    /// Seats abreast per group, window to window: [3, 3], [3, 3, 3], [3, 4, 3], [2, 2].
    var layout: [Int]

    /// Half the fuselage's width at a station: an elliptic nose, a straight barrel, a tail cone that leaves
    /// the barrel tangentially.
    func halfWidth(_ x: Double) -> Double {
        let r = width / 2
        if x <= 0 { return 0 }
        if x < noseLength {
            let t = 1 - x / noseLength
            return r * pow(1 - pow(t, 2.2), 1 / 2.2)
        }
        let taperStart = length - tailLength
        if x > taperStart {
            let u = min((x - taperStart) / tailLength, 1)
            return tailWidth / 2 + (r - tailWidth / 2) * (1 - pow(u, 1.7))
        }
        return r
    }

    /// The fuselage outline as a closed polygon (top side then bottom side), 160 stations.
    func fuselage() -> [CGPoint] {
        let n = 160
        let xs = (0...n).map { i -> Double in
            // Denser near the nose, where the curve turns fastest.
            let t = Double(i) / Double(n)
            return length * (t < 0.2 ? pow(t / 0.2, 1.6) * 0.2 : t)
        }
        let top = xs.map { CGPoint(x: $0, y: halfWidth($0)) }
        let bottom = xs.reversed().map { CGPoint(x: $0, y: -halfWidth($0)) }
        return top + bottom
    }

    /// The cabin floor's stretch inside the barrel, first door to last door: where the class zones go.
    var cabin: ClosedRange<Double> { (doors.first ?? noseLength) + 1.4...(doors.last ?? length - tailLength) - 0.4 }

    /// The tightest box around the whole plan.
    var bounds: CGRect {
        let half = max(wing.span, stab.span) / 2
        let props = engines.map { $0.y + $0.prop / 2 }.max() ?? 0
        let y = max(half, props)
        return CGRect(x: 0, y: -y, width: length, height: 2 * y)
    }
}

// MARK: - Drawing

/// Our technical drawing of a family in plan, nose at the right: fuselage, wings with their hinge lines and
/// flap track fairings, nacelles, tailplane and fin, cockpit windscreen, doors and window rows, drawn in
/// hairlines over translucent panel fills, with the centreline and quarter-chord construction lines, the
/// overall length and span dimensioned, the cabin's class zones in the barrel (lettered F, J, W, Y) and the
/// cut of section A-A. Decorative: the figures sit in the panel's text beside it.
struct PlanDrawing: View {
    var family: PlanFamily
    /// Class zone shares, front to back (First, Business, Premium, Economy): 0 hides a zone.
    var zones: [(code: String, share: Double)]
    var ink: Color = Theme.blueprintInk

    /// Points per metre and the metres-to-view transform for a frame of `size`.
    static func transform(_ g: PlanGeometry, size: CGSize) -> CGAffineTransform {
        let b = g.bounds
        // Margins: room for the span dimension at the left, the length dimension under the drawing.
        let left: CGFloat = 34, right: CGFloat = 14, top: CGFloat = 10, bottom: CGFloat = 34
        let s = min((size.width - left - right) / b.width, (size.height - top - bottom) / b.height)
        let drawnW = b.width * s, drawnH = b.height * s
        let x0 = left + (size.width - left - right - drawnW) / 2
        let cy = top + (size.height - top - bottom - drawnH) / 2 + drawnH / 2
        // Nose (x = 0) at the right: view x = x0 + drawnW - x * s; y up.
        return CGAffineTransform(a: -s, b: 0, c: 0, d: -s, tx: x0 + drawnW, ty: cy)
    }

    /// The frame's height for a width: the plan's proportions plus the dimension margins.
    static func height(for width: CGFloat, family: PlanFamily) -> CGFloat {
        let b = family.plan.bounds
        return min((width - 48) * b.height / b.width + 44, width * 1.05)
    }

    var body: some View {
        let g = family.plan
        Canvas { ctx, size in
            let t = Self.transform(g, size: size)
            let s = t.a.magnitude
            let hair: CGFloat = 0.75
            let fine = StrokeStyle(lineWidth: 0.5, lineCap: .round, lineJoin: .round)
            let main = StrokeStyle(lineWidth: hair, lineCap: .round, lineJoin: .round)
            let construction = StrokeStyle(lineWidth: 0.5, dash: [10, 3, 2, 3])
            func poly(_ pts: [CGPoint], close: Bool = true) -> Path {
                var p = Path(); p.addLines(pts); if close { p.closeSubpath() }; return p.applying(t)
            }
            func mirrored(_ pts: [CGPoint]) -> [CGPoint] { pts.map { CGPoint(x: $0.x, y: -$0.y) } }

            let fuselage = poly(g.fuselage())

            // Construction: the centreline past both ends, the wing's quarter-chord and root stations.
            var centre = Path()
            centre.move(to: CGPoint(x: -1.5, y: 0)); centre.addLine(to: CGPoint(x: g.length + 1.5, y: 0))
            ctx.stroke(centre.applying(t), with: .color(ink.opacity(0.4)), style: construction)
            var quarter = Path()
            for side in [1.0, -1.0] {
                let r = g.width / 2, tip = g.wing.span / 2
                quarter.move(to: CGPoint(x: g.wing.leadingEdge(r) + g.wing.chord(r) / 4, y: side * r))
                quarter.addLine(to: CGPoint(x: g.wing.leadingEdge(tip) + g.wing.tipChord / 4, y: side * tip))
            }
            ctx.stroke(quarter.applying(t), with: .color(ink.opacity(0.32)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

            // Surfaces: under the fuselage for a low wing, over it for a high wing or a T-tail.
            func surface(_ p: Planform, over: Bool) {
                let from = over ? 0 : g.width / 2 * 0.98
                for side in [1.0, -1.0] {
                    let half = p.half(from: from)
                    let pts = side > 0 ? half : mirrored(half)
                    let path = poly(pts + (over ? mirrored(Array(half.reversed())).dropFirst().map { $0 } : []), close: true)
                    ctx.fill(path, with: .color(Theme.blueprint.opacity(0.82)))
                    ctx.fill(path, with: .color(ink.opacity(0.07)))
                    ctx.stroke(path, with: .color(ink), style: main)
                    if over { break }
                }
            }
            func hinges(_ p: Planform, inboard: Double, fairings: [Double]) {
                // Flap and aileron hinge line at 72% chord, then the flap track fairings behind it.
                var hinge = Path()
                let tip = p.span / 2 - 0.4
                let ys = stride(from: inboard, through: tip, by: (tip - inboard) / 24).map { $0 }
                for side in [1.0, -1.0] {
                    hinge.addLines(ys.map { CGPoint(x: p.leadingEdge($0) + 0.72 * p.chord($0), y: side * $0) })
                    // Flap to aileron break.
                    let a = inboard + (tip - inboard) * 0.7
                    hinge.move(to: CGPoint(x: p.leadingEdge(a) + 0.72 * p.chord(a), y: side * a))
                    hinge.addLine(to: CGPoint(x: p.trailingEdge(a), y: side * a))
                    // Spoiler line at 58%.
                    let sp = ys.filter { $0 < a }
                    hinge.move(to: CGPoint(x: p.leadingEdge(sp[0]) + 0.58 * p.chord(sp[0]), y: side * sp[0]))
                    for y in sp.dropFirst() { hinge.addLine(to: CGPoint(x: p.leadingEdge(y) + 0.58 * p.chord(y), y: side * y)) }
                }
                ctx.stroke(hinge.applying(t), with: .color(ink.opacity(0.55)), style: fine)
                var fair = Path()
                for side in [1.0, -1.0] {
                    for y in fairings {
                        let te = p.trailingEdge(y), c = p.chord(y)
                        let w = max(0.16, g.width * 0.07)
                        let start = te - c * 0.12, end = te + c * 0.22
                        var f = Path()
                        f.move(to: CGPoint(x: start, y: side * (y - w)))
                        f.addLine(to: CGPoint(x: end - c * 0.06, y: side * (y - w * 0.6)))
                        f.addQuadCurve(to: CGPoint(x: end - c * 0.06, y: side * (y + w * 0.6)), control: CGPoint(x: end + c * 0.02, y: side * y))
                        f.addLine(to: CGPoint(x: start, y: side * (y + w)))
                        fair.addPath(f)
                    }
                }
                ctx.fill(fair.applying(t), with: .color(ink.opacity(0.1)))
                ctx.stroke(fair.applying(t), with: .color(ink.opacity(0.75)), style: fine)
            }
            func nacelles() {
                for e in g.engines {
                    for side in [1.0, -1.0] {
                        let y = side * e.y
                        let r = CGRect(x: e.x, y: y - e.width / 2, width: e.length, height: e.width)
                        if e.rear {
                            var pylon = Path()
                            pylon.addRect(CGRect(x: e.x + e.length * 0.3, y: side > 0 ? g.width / 2 * 0.8 : y + e.width / 2,
                                                 width: e.length * 0.4, height: abs(y) - e.width / 2 - g.width / 2 * 0.8))
                            ctx.fill(pylon.applying(t), with: .color(ink.opacity(0.1)))
                            ctx.stroke(pylon.applying(t), with: .color(ink), style: main)
                        }
                        let shell = Path(roundedRect: r, cornerSize: CGSize(width: e.width * 0.42, height: e.width * 0.42)).applying(t)
                        ctx.fill(shell, with: .color(Theme.blueprint))
                        ctx.fill(shell, with: .color(ink.opacity(0.14)))
                        ctx.stroke(shell, with: .color(ink), style: main)
                        var detail = Path()
                        // Inlet lip, fan cowl split, and the core nozzle's plug.
                        for f in [0.1, 0.55] {
                            detail.move(to: CGPoint(x: e.x + e.length * f, y: y - e.width / 2 * 0.92))
                            detail.addLine(to: CGPoint(x: e.x + e.length * f, y: y + e.width / 2 * 0.92))
                        }
                        detail.move(to: CGPoint(x: e.x + e.length, y: y - e.width * 0.18))
                        detail.addLine(to: CGPoint(x: e.x + e.length * 1.1, y: y))
                        detail.addLine(to: CGPoint(x: e.x + e.length, y: y + e.width * 0.18))
                        ctx.stroke(detail.applying(t), with: .color(ink.opacity(0.6)), style: fine)
                        if e.prop > 0 {
                            var prop = Path()
                            prop.addEllipse(in: CGRect(x: e.x - 0.55, y: y - 0.35, width: 0.7, height: 0.7))
                            prop.move(to: CGPoint(x: e.x - 0.15, y: y - e.prop / 2))
                            prop.addLine(to: CGPoint(x: e.x - 0.15, y: y + e.prop / 2))
                            ctx.stroke(prop.applying(t), with: .color(ink), style: main)
                            // The disc, faint.
                            var disc = Path()
                            disc.addRect(CGRect(x: e.x - 0.35, y: y - e.prop / 2, width: 0.4, height: e.prop))
                            ctx.fill(disc.applying(t), with: .color(ink.opacity(0.08)))
                        }
                    }
                }
            }

            let fairings: [Double] = {
                let w = g.wing, r = g.width / 2, tip = w.span / 2
                return [0.24, 0.42, 0.6, 0.76].map { r + (tip - r) * $0 }
            }()
            if !g.highWing {
                // The nacelles hang under the wing: their fronts stand ahead of the leading edge, the rest
                // goes under the wing's panel.
                if !g.engines.contains(where: \.rear) { nacelles() }
                surface(g.wing, over: false)
                hinges(g.wing, inboard: g.width / 2 + 0.2, fairings: fairings)
            }
            if !g.tTail { surface(g.stab, over: false) }

            // The fuselage over the low surfaces.
            ctx.fill(fuselage, with: .color(Theme.blueprint))
            ctx.fill(fuselage, with: .color(ink.opacity(0.08)))
            ctx.stroke(fuselage, with: .color(ink), style: StrokeStyle(lineWidth: 1, lineJoin: .round))

            // Wing box carry-through, hidden: dashed inside the barrel.
            if !g.highWing {
                var box = Path()
                let r = g.width / 2
                box.move(to: CGPoint(x: g.wing.leadingEdge(r), y: r)); box.addLine(to: CGPoint(x: g.wing.apex + 0.6, y: 0))
                box.addLine(to: CGPoint(x: g.wing.leadingEdge(r), y: -r))
                box.move(to: CGPoint(x: g.wing.trailingEdge(r), y: r)); box.addLine(to: CGPoint(x: g.wing.trailingEdge(r), y: -r))
                ctx.stroke(box.applying(t), with: .color(ink.opacity(0.35)), style: StrokeStyle(lineWidth: 0.5, dash: [2.5, 2.5]))
            }

            // Class zones along the cabin, front to back, and their letters.
            let cabin = g.cabin
            let shown = zones.filter { $0.share > 0 }
            let total = max(shown.reduce(0) { $0 + $1.share }, 1e-9)
            let inset = g.width * 0.2
            let minimum = (cabin.upperBound - cabin.lowerBound) * 0.07
            let spare = (cabin.upperBound - cabin.lowerBound) - minimum * Double(shown.count) - 0.25 * Double(max(shown.count - 1, 0))
            var x = cabin.lowerBound
            for (i, z) in shown.enumerated() {
                let len = minimum + max(spare, 0) * z.share / total
                let rect = CGRect(x: x, y: -g.width / 2 + inset, width: len, height: g.width - 2 * inset)
                let zone = Path(roundedRect: rect, cornerSize: CGSize(width: 0.15, height: 0.15)).applying(t)
                let strength = [0.42, 0.32, 0.24, 0.16][min(i + (4 - shown.count), 3)]
                ctx.fill(zone, with: .color(ink.opacity(z.code == "Y" ? 0.16 : strength)))
                ctx.stroke(zone, with: .color(ink.opacity(0.7)), style: fine)
                // Seat row ticks in the zone, faint: a row every 0.8 m.
                var rows = Path()
                var rx = x + 0.4
                while rx < x + len - 0.2 {
                    rows.move(to: CGPoint(x: rx, y: -g.width / 2 + inset + 0.08))
                    rows.addLine(to: CGPoint(x: rx, y: g.width / 2 - inset - 0.08))
                    rx += 0.81
                }
                ctx.stroke(rows.applying(t), with: .color(ink.opacity(0.18)), lineWidth: 0.5)
                let centre = CGPoint(x: x + len / 2, y: 0).applying(t)
                let letter = min(rect.height * s * 0.5, 11)
                if len * s > letter * 1.4 {
                    ctx.draw(Text(ui: z.code).font(.system(size: letter, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.blueprint), at: centre)
                }
                x += len + 0.25
            }

            // Doors and overwing exits: a break in the wall; then the window rows.
            var openings = Path()
            for (stations, len) in [(g.doors, 1.0), (g.exits, 0.6)] {
                for d in stations {
                    for side in [1.0, -1.0] {
                        let hw = g.halfWidth(d + len / 2)
                        openings.addRect(CGRect(x: d, y: side > 0 ? hw - g.width * 0.07 : -hw, width: len, height: g.width * 0.07))
                    }
                }
            }
            ctx.fill(openings.applying(t), with: .color(ink.opacity(0.35)))
            ctx.stroke(openings.applying(t), with: .color(ink), style: fine)
            var windows = Path()
            var wx = g.windows.from
            let blocked = g.doors.map { ($0 - 0.3)...($0 + 1.3) } + g.exits.map { ($0 - 0.1)...($0 + 0.7) }
            while wx <= g.windows.to {
                if !blocked.contains(where: { $0.contains(wx) }) {
                    for side in [1.0, -1.0] {
                        let y = side * (g.halfWidth(wx) - g.width * 0.035)
                        windows.move(to: CGPoint(x: wx, y: y)); windows.addLine(to: CGPoint(x: wx + min(0.26, g.windows.pitch * 0.45), y: y))
                    }
                }
                wx += g.windows.pitch
            }
            ctx.stroke(windows.applying(t), with: .color(ink.opacity(0.8)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))

            // Cockpit windscreen and side windows.
            var screen = Path()
            let n = g.noseLength, w = g.width
            let x1 = n * 0.42, x2 = n * 0.66
            for side in [1.0, -1.0] {
                screen.addLines([CGPoint(x: x1, y: side * w * 0.03), CGPoint(x: x1 + n * 0.05, y: side * g.halfWidth(x1 + n * 0.05) * 0.78),
                                 CGPoint(x: x2, y: side * g.halfWidth(x2) * 0.84), CGPoint(x: x2 - n * 0.02, y: side * w * 0.03)])
                screen.closeSubpath()
                screen.addLines([CGPoint(x: x2 + n * 0.04, y: side * g.halfWidth(x2 + n * 0.04) * 0.9),
                                 CGPoint(x: x2 + n * 0.22, y: side * g.halfWidth(x2 + n * 0.22) * 0.93)])
            }
            ctx.fill(screen.applying(t), with: .color(ink.opacity(0.18)))
            ctx.stroke(screen.applying(t), with: .color(ink.opacity(0.85)), style: fine)

            // High wing and T-tail over the fuselage.
            if g.highWing {
                surface(g.wing, over: true)
                hinges(g.wing, inboard: g.width / 2 + 0.2, fairings: [])
                nacelles()
            }
            if g.engines.contains(where: \.rear) { nacelles() }
            // The fin's root, seen from above.
            var fin = Path()
            fin.move(to: CGPoint(x: g.fin.x, y: 0))
            fin.addQuadCurve(to: CGPoint(x: g.fin.x + g.fin.length, y: 0), control: CGPoint(x: g.fin.x + g.fin.length * 0.3, y: g.fin.thickness))
            fin.addQuadCurve(to: CGPoint(x: g.fin.x, y: 0), control: CGPoint(x: g.fin.x + g.fin.length * 0.3, y: -g.fin.thickness))
            ctx.fill(fin.applying(t), with: .color(ink.opacity(0.18)))
            ctx.stroke(fin.applying(t), with: .color(ink), style: main)
            if g.tTail { surface(g.stab, over: true) }

            // Section A-A through the cabin's middle: thick ends, arrows looking forward.
            let ax = cabin.lowerBound + (cabin.upperBound - cabin.lowerBound) * 0.62
            let reach = g.width / 2 + max(g.width * 0.35, 9 / s)
            for side in [1.0, -1.0] {
                let a = CGPoint(x: ax, y: side * reach).applying(t)
                let b = CGPoint(x: ax, y: side * (g.width / 2 + 2 / s)).applying(t)
                var cut = Path(); cut.move(to: a); cut.addLine(to: b)
                ctx.stroke(cut, with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .butt))
                var arrow = Path()
                arrow.move(to: a); arrow.addLine(to: CGPoint(x: a.x + 9, y: a.y))
                arrow.move(to: CGPoint(x: a.x + 9, y: a.y)); arrow.addLine(to: CGPoint(x: a.x + 5, y: a.y - 2.5))
                arrow.move(to: CGPoint(x: a.x + 9, y: a.y)); arrow.addLine(to: CGPoint(x: a.x + 5, y: a.y + 2.5))
                ctx.stroke(arrow, with: .color(ink), lineWidth: 0.8)
                ctx.draw(Text("A").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(ink),
                         at: CGPoint(x: a.x + 3, y: a.y + (side > 0 ? -7 : 7)))
            }

            // Dimensions: overall length under the drawing, span at the left.
            let b = g.bounds
            let dimInk = GraphicsContext.Shading.color(ink.opacity(0.75))
            func dimension(from p: CGPoint, to q: CGPoint, label: String, vertical: Bool) {
                var line = Path(); line.move(to: p); line.addLine(to: q)
                ctx.stroke(line, with: dimInk, lineWidth: 0.5)
                var ticks = Path()
                for e in [p, q] {
                    // Architectural ticks: short 45 degree strokes.
                    ticks.move(to: CGPoint(x: e.x - 3, y: e.y + 3)); ticks.addLine(to: CGPoint(x: e.x + 3, y: e.y - 3))
                }
                ctx.stroke(ticks, with: .color(ink), lineWidth: 0.9)
                let mid = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
                var label = ctx.resolve(Text(ui: label).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(ink))
                label.shading = .color(ink)
                let sz = label.measure(in: CGSize(width: 200, height: 40))
                if vertical {
                    ctx.drawLayer { l in
                        l.translateBy(x: mid.x, y: mid.y); l.rotate(by: .degrees(-90))
                        l.fill(Path(CGRect(x: -sz.width / 2 - 3, y: -sz.height / 2, width: sz.width + 6, height: sz.height)),
                               with: .color(Theme.blueprint))
                        l.draw(label, at: .zero)
                    }
                } else {
                    ctx.fill(Path(CGRect(x: mid.x - sz.width / 2 - 3, y: mid.y - sz.height / 2, width: sz.width + 6, height: sz.height)),
                             with: .color(Theme.blueprint))
                    ctx.draw(label, at: mid)
                }
            }
            let lowest = CGPoint(x: 0, y: b.minY).applying(t).y
            let dimY = lowest + 18
            var ext = Path()
            for xm in [0.0, g.length] {
                let top = CGPoint(x: xm, y: -g.halfWidth(xm) - 0.3).applying(t)
                ext.move(to: CGPoint(x: top.x, y: xm == 0 ? CGPoint(x: 0, y: 0).applying(t).y + 4 : top.y + 4))
                ext.addLine(to: CGPoint(x: top.x, y: dimY + 4))
            }
            let tipLE = g.wing.leadingEdge(g.wing.span / 2)
            let tipX = CGPoint(x: tipLE + g.wing.tipChord, y: 0).applying(t).x
            let spanX = min(CGPoint(x: g.length, y: 0).applying(t).x, tipX) - 16
            for side in [1.0, -1.0] {
                let tip = CGPoint(x: tipLE + g.wing.tipChord, y: side * g.wing.span / 2).applying(t)
                ext.move(to: CGPoint(x: tip.x - 3, y: tip.y)); ext.addLine(to: CGPoint(x: spanX - 4, y: tip.y))
            }
            ctx.stroke(ext, with: .color(ink.opacity(0.4)), lineWidth: 0.5)
            dimension(from: CGPoint(x: CGPoint(x: g.length, y: 0).applying(t).x, y: dimY),
                      to: CGPoint(x: CGPoint(x: 0, y: 0).applying(t).x, y: dimY),
                      label: String(format: "%.2f m", g.length), vertical: false)
            dimension(from: CGPoint(x: spanX, y: CGPoint(x: 0, y: g.wing.span / 2).applying(t).y),
                      to: CGPoint(x: spanX, y: CGPoint(x: 0, y: -g.wing.span / 2).applying(t).y),
                      label: String(format: "%.2f m", g.wing.span), vertical: true)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Section A-A

/// The cabin's cross-section in metres, for the half section drawn to scale: the fuselage's outer radius,
/// the lining inside it, the floor below the centre, and the seat row across it (economy seats, their
/// armrests and the aisles). Figures are the type families' published cabin dimensions, rounded.
struct CabinSection: Sendable {
    /// Outer radius of the fuselage.
    var radius: Double
    /// Skin, frames and lining between the outside and the cabin wall.
    var wall: Double
    /// Cabin floor below the fuselage's centre.
    var floorDrop: Double
    /// Seat cushion between the armrests.
    var seat: Double
    var armrest: Double
    var aisle: Double
    /// Window height in the wall.
    var window: Double
    /// Overhead bin: the bottom's height above the floor, and its reach in from the wall.
    var binBottom: Double, binDepth: Double
    /// Seats abreast per group, left to right.
    var layout: [Int]

    // Seat heights above the floor (economy, front view).
    static let cushionTop = 0.46
    static let armrestTop = 0.66, armrestHeight = 0.05
    static let backTop = 1.10, backBottom = 0.40, headrestBottom = 0.97
    static let trayTop = 0.80, trayBottom = 0.56, pocket = 0.50
    static let beamTop = 0.36, beamHeight = 0.05

    init(_ family: PlanFamily) {
        let layout = family.plan.layout
        let r = family.plan.width / 2
        switch family {
        case .narrow:
            // A320 / 737: 3.95 m outside, 18 in seats, 19 in aisle.
            self.init(radius: r, wall: 0.10, floorDrop: 0.70, seat: 0.457, armrest: 0.05, aisle: 0.48,
                      window: 0.33, binBottom: 1.62, binDepth: 0.55, layout: layout)
        case .wideTwin:
            // 787 / A350: 17 in seats nine abreast, 18 in aisles.
            self.init(radius: r, wall: 0.12, floorDrop: 0.95, seat: 0.432, armrest: 0.045, aisle: 0.46,
                      window: 0.47, binBottom: 1.70, binDepth: 0.62, layout: layout)
        case .wideQuad:
            // A380 main deck / 747: 18 in seats ten abreast.
            self.init(radius: r, wall: 0.13, floorDrop: 1.20, seat: 0.46, armrest: 0.05, aisle: 0.50,
                      window: 0.40, binBottom: 1.72, binDepth: 0.65, layout: layout)
        case .regional:
            // E-Jet / A220 four abreast.
            self.init(radius: r, wall: 0.07, floorDrop: 0.62, seat: 0.46, armrest: 0.05, aisle: 0.50,
                      window: 0.33, binBottom: 1.55, binDepth: 0.42, layout: layout)
        case .rearJet:
            // CRJ: a 2.69 m tube, 17 in seats, 16 in aisle.
            self.init(radius: r, wall: 0.06, floorDrop: 0.55, seat: 0.44, armrest: 0.045, aisle: 0.41,
                      window: 0.28, binBottom: 1.45, binDepth: 0.36, layout: layout)
        case .turboprop:
            // ATR 72: 2.87 m outside, four abreast.
            self.init(radius: r, wall: 0.06, floorDrop: 0.58, seat: 0.45, armrest: 0.05, aisle: 0.45,
                      window: 0.38, binBottom: 1.50, binDepth: 0.38, layout: layout)
        }
    }

    init(radius: Double, wall: Double, floorDrop: Double, seat: Double, armrest: Double, aisle: Double,
         window: Double, binBottom: Double, binDepth: Double, layout: [Int]) {
        self.radius = radius; self.wall = wall; self.floorDrop = floorDrop; self.seat = seat
        self.armrest = armrest; self.aisle = aisle; self.window = window; self.binBottom = binBottom
        self.binDepth = binDepth; self.layout = layout
    }

    var lining: Double { radius - wall }

    /// The row's width, armrests and aisles included.
    var rowWidth: Double {
        layout.reduce(0) { $0 + Double($1) * seat + Double($1 + 1) * armrest } + Double(layout.count - 1) * aisle
    }

    /// Each seat cushion's left and right edge across the cabin, in metres from the centreline (negative
    /// left), grouped as the layout, the row centred.
    var seats: [[ClosedRange<Double>]] {
        var x = -rowWidth / 2
        return layout.map { n in
            x += armrest
            let group = (0..<n).map { i -> ClosedRange<Double> in
                let a = x + Double(i) * (seat + armrest)
                return a...(a + seat)
            }
            x += Double(n) * (seat + armrest) + aisle
            return group
        }
    }

    /// The lining's half width at a height above the floor (0 above the top).
    func liningHalfWidth(at height: Double) -> Double {
        let y = height - floorDrop
        return sqrt(max(0, lining * lining - y * y))
    }
}

/// The cabin cut across at A-A, looking forward, left half only (a half section, broken at the centreline),
/// drawn to scale from `CabinSection`: the fuselage skin and its lining, the floor beam and the hold under
/// it, the overhead bin, the window in the wall, and the economy seats of the family's layout seen from
/// behind: backrests with their headrest covers, tray tables and pockets, the end armrests, and the frame and
/// legs on the seat tracks. The seat group
/// next to the aisle, cut by the centreline, is ghosted. Each seat of the left group carries its count.
struct HalfSection: View {
    var family: PlanFamily
    /// Count over each seat of the left group, window first ("5", "6", "24"); a 2-abreast group takes the
    /// window and aisle counts.
    var counts: [String]
    /// Under each seat: "Window", "Middle", "Aisle".
    var names: [String]
    var ink: Color = Theme.blueprintInk
    @ScaledMetric(relativeTo: .body) private var countSize: CGFloat = 17

    /// The frame for a width: the view shows from over the bin to the seat names under the floor.
    static func aspect() -> CGFloat { 1 / 1.2 }

    /// "Win", "Mid", "Aisle".
    static func short(_ name: String) -> String { name.count > 5 ? String(name.prefix(3)) : name }

    /// Points per metre, and the fuselage centre, for a frame: the skin's left edge 4% in from the left, the
    /// centreline near the right edge, the top cropped above the bins.
    static func scale(_ size: CGSize, _ section: CabinSection) -> (s: CGFloat, centre: CGPoint) {
        let s = size.width / CGFloat(section.radius * 1.06)
        let r = CGFloat(section.radius) * s
        let floorY = r * 0.74 + CGFloat(section.floorDrop) * s
        // Keep the floor and the names under it in the frame on the smaller tubes.
        let lift = max(0, floorY + 30 - size.height)
        return (s, CGPoint(x: size.width * 0.985, y: r * 0.74 - lift))
    }

    /// A point across the cabin (metres from the centreline) at a height above the floor, on screen.
    static func point(_ x: Double, _ h: Double, _ section: CabinSection, _ s: CGFloat, _ c: CGPoint) -> CGPoint {
        CGPoint(x: c.x + CGFloat(x) * s, y: c.y + CGFloat(section.floorDrop - h) * s)
    }

    var body: some View {
        let section = CabinSection(family)
        GeometryReader { geo in
            let (s, c) = Self.scale(geo.size, section)
            let seats = section.seats
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    draw(&ctx, size: size, section: section, s: s, c: c)
                }
                .accessibilityHidden(true)
                // Counts on the solid seats' backrests, their names under the floor.
                ForEach(Array((seats.first ?? []).enumerated()), id: \.offset) { i, span in
                    if i < counts.count {
                        let mid = (span.lowerBound + span.upperBound) / 2
                        let w = CGFloat(span.upperBound - span.lowerBound) * s
                        Text(counts[i])
                            .font(.system(size: countSize, weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .rollingDigits(Double(counts[i]))
                            .frame(width: w + 6)
                            .position(Self.point(mid, 0.895, section, s, c))
                        Text(w < 40 ? Self.short(names[i]) : names[i])
                            .font(.system(size: w < 40 ? 9 : 10, weight: .medium, design: .monospaced))
                            .textCase(.uppercase)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .opacity(0.85)
                            .frame(width: w + 8)
                            .position(x: Self.point(mid, 0, section, s, c).x, y: Self.point(mid, 0, section, s, c).y + 14)
                    }
                }
            }
        }
        .aspectRatio(Self.aspect(), contentMode: .fit)
        .foregroundStyle(ink)
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, section: CabinSection, s: CGFloat, c: CGPoint) {
        typealias C = CabinSection
        func pt(_ x: Double, _ h: Double) -> CGPoint {
            CGPoint(x: c.x + CGFloat(x) * s, y: c.y + CGFloat(section.floorDrop - h) * s)
        }
        func m(_ v: Double) -> CGFloat { CGFloat(v) * s }
        let r = m(section.radius), lining = m(section.lining)
        let line = ink, faint = ink.opacity(0.45)

        // Skin, its fill, the lining.
        var fill = Path()
        fill.addArc(center: c, radius: r, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        fill.closeSubpath()
        ctx.fill(fill, with: .color(ink.opacity(0.05)))
        var skin = Path()
        skin.addArc(center: c, radius: r, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        ctx.stroke(skin, with: .color(line), lineWidth: 1.1)
        // The lining runs from the floor up to the bin, then the ceiling panel from the bin to the centre.
        let floorHalf = section.liningHalfWidth(at: 0)
        let binHalf = section.liningHalfWidth(at: section.binBottom + 0.38)
        var wall = Path()
        wall.move(to: pt(-floorHalf, 0))
        for i in 0...24 {
            let h = Double(i) / 24 * (section.binBottom + 0.38)
            wall.addLine(to: pt(-section.liningHalfWidth(at: h), h))
        }
        ctx.stroke(wall, with: .color(faint), lineWidth: 0.6)
        let ceiling = section.binBottom + 0.62
        var panel = Path()
        panel.move(to: pt(-binHalf + section.binDepth, section.binBottom + 0.30))
        panel.addQuadCurve(to: pt(0, ceiling), control: pt(-binHalf * 0.35, ceiling))
        ctx.stroke(panel, with: .color(faint), lineWidth: 0.6)
        // Frames between skin and lining: short ticks.
        for deg in stride(from: 100.0, through: 260.0, by: 16.0) {
            let a = Angle.degrees(deg).radians
            var tick = Path()
            tick.move(to: CGPoint(x: c.x + cos(a) * lining, y: c.y + sin(a) * lining))
            tick.addLine(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
            ctx.stroke(tick, with: .color(ink.opacity(0.25)), lineWidth: 0.5)
        }

        // Floor panel and beam, the hold under it.
        var floor = Path(); floor.move(to: pt(-floorHalf, 0)); floor.addLine(to: pt(0, 0))
        ctx.stroke(floor, with: .color(line), lineWidth: 1.1)
        var beam = Path()
        beam.addRect(CGRect(origin: pt(-floorHalf * 0.96, 0), size: CGSize(width: m(floorHalf * 0.96), height: m(0.18))))
        ctx.stroke(beam, with: .color(ink.opacity(0.35)), lineWidth: 0.5)
        let holdTop = -0.30, holdBottom = -min(section.radius + section.floorDrop - 0.25, 1.75)
        var hold = Path()
        let holdHalf = min(section.liningHalfWidth(at: holdBottom) , floorHalf) * 0.8
        hold.addRect(CGRect(x: pt(-holdHalf, holdTop).x, y: pt(0, holdTop).y, width: m(holdHalf), height: m(holdTop - holdBottom)))
        ctx.stroke(hold, with: .color(ink.opacity(0.35)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))

        // Window, centred at shoulder height.
        let wy = 0.95
        let wx = -section.liningHalfWidth(at: wy)
        var window = Path()
        window.addRoundedRect(in: CGRect(x: pt(wx, 0).x - m(section.wall) - 1, y: pt(0, wy + section.window / 2).y,
                                         width: m(section.wall) + 2, height: m(section.window)),
                              cornerSize: CGSize(width: m(0.04), height: m(0.04)))
        ctx.fill(window, with: .color(Theme.blueprint))
        ctx.stroke(window, with: .color(line), lineWidth: 0.8)

        // Overhead bin: against the lining, a flat floor, the door's rounded face.
        let b0 = section.binBottom, b1 = section.binBottom + 0.38
        let bx = -section.liningHalfWidth(at: b0) + 0.02
        var bin = Path()
        bin.move(to: pt(bx, b0))
        bin.addLine(to: pt(bx + section.binDepth, b0))
        bin.addQuadCurve(to: pt(bx + section.binDepth - 0.05, b1 - 0.08), control: pt(bx + section.binDepth + 0.06, b0 + 0.2))
        bin.addLine(to: pt(-section.liningHalfWidth(at: b1) + 0.02, b1))
        for i in 0...8 {
            let h = b1 - Double(i) / 8 * (b1 - b0)
            bin.addLine(to: pt(-section.liningHalfWidth(at: h) + 0.02, h))
        }
        bin.closeSubpath()
        ctx.fill(bin, with: .color(ink.opacity(0.08)))
        ctx.stroke(bin, with: .color(ink.opacity(0.8)), lineWidth: 0.7)
        // Passenger service unit under the bin: reading lights and the air outlet.
        var psu = Path()
        psu.addRoundedRect(in: CGRect(origin: pt(bx + 0.04, b0 - 0.0), size: CGSize(width: m(section.binDepth - 0.1), height: m(0.06))),
                           cornerSize: CGSize(width: 1.5, height: 1.5))
        ctx.stroke(psu, with: .color(ink.opacity(0.5)), lineWidth: 0.5)

        // Seats, group by group: the left group solid, the others ghosted and cut at the centreline.
        for (g, group) in section.seats.enumerated() {
            let solid = g == 0
            ctx.drawLayer { l in
                l.clip(to: Path(CGRect(x: 0, y: 0, width: c.x, height: size.height)))
                let stroke = ink.opacity(solid ? 0.95 : 0.3)
                let tint = ink.opacity(solid ? 0.16 : 0.03)
                let lw: CGFloat = solid ? 0.8 : 0.5
                guard let first = group.first, let last = group.last, first.lowerBound < 0 else { return }
                let left = first.lowerBound - section.armrest, right = last.upperBound + section.armrest
                // Frame: the beam under the cushions, two legs to the seat tracks, their braces.
                var frame = Path()
                frame.addRect(CGRect(origin: pt(left + 0.04, C.beamTop), size: CGSize(width: m(right - left - 0.08), height: m(C.beamHeight))))
                for f in [0.22, 0.78] {
                    let x = left + (right - left) * f
                    frame.move(to: pt(x - 0.03, C.beamTop - C.beamHeight)); frame.addLine(to: pt(x - 0.05, 0.02))
                    frame.move(to: pt(x + 0.03, C.beamTop - C.beamHeight)); frame.addLine(to: pt(x + 0.05, 0.02))
                    frame.move(to: pt(x - 0.05, 0.10)); frame.addLine(to: pt(x + 0.05, 0.10))
                    frame.addRect(CGRect(origin: pt(x - 0.08, 0.02), size: CGSize(width: m(0.16), height: m(0.02))))
                }
                l.stroke(frame, with: .color(stroke.opacity(0.8)), lineWidth: lw * 0.8)
                for span in group {
                    // Seen from behind, looking forward: the backrest's shell, a little narrower at the
                    // headrest, its rounded shoulders, the headrest cover, the tray table and its latch,
                    // the literature pocket under it.
                    let a = span.lowerBound - 0.01, b = span.upperBound + 0.01, mid = (a + b) / 2
                    var back = Path()
                    back.move(to: pt(a + 0.02, C.backBottom))
                    back.addLine(to: pt(a + 0.004, 0.86))
                    back.addQuadCurve(to: pt(a + 0.07, C.backTop), control: pt(a + 0.012, C.backTop))
                    back.addLine(to: pt(b - 0.07, C.backTop))
                    back.addQuadCurve(to: pt(b - 0.004, 0.86), control: pt(b - 0.012, C.backTop))
                    back.addLine(to: pt(b - 0.02, C.backBottom))
                    back.addQuadCurve(to: pt(a + 0.02, C.backBottom), control: pt(mid, C.backBottom - 0.04))
                    l.fill(back, with: .color(tint))
                    l.stroke(back, with: .color(stroke), lineWidth: lw)
                    var detail = Path()
                    // Headrest cover.
                    detail.move(to: pt(a + 0.02, C.headrestBottom))
                    detail.addQuadCurve(to: pt(b - 0.02, C.headrestBottom), control: pt(mid, C.headrestBottom - 0.025))
                    // Tray table, latch.
                    detail.addRoundedRect(in: CGRect(origin: pt(a + 0.045, C.trayTop), size: CGSize(width: m(b - a - 0.09), height: m(C.trayTop - C.trayBottom))),
                                          cornerSize: CGSize(width: m(0.02), height: m(0.02)))
                    detail.addRoundedRect(in: CGRect(origin: pt(mid - 0.025, C.trayTop + 0.02), size: CGSize(width: m(0.05), height: m(0.016))),
                                          cornerSize: CGSize(width: m(0.008), height: m(0.008)))
                    // Literature pocket.
                    detail.move(to: pt(a + 0.05, C.pocket))
                    detail.addQuadCurve(to: pt(b - 0.05, C.pocket), control: pt(mid, C.pocket - 0.035))
                    l.stroke(detail, with: .color(stroke.opacity(0.7)), lineWidth: lw * 0.75)
                }
                // Armrests: the inner ones hide behind the backrests, the two at the group's ends show.
                var arms = Path()
                for i in [0, group.count] {
                    let x = i < group.count ? group[i].lowerBound - section.armrest : last.upperBound
                    arms.addRoundedRect(in: CGRect(origin: pt(x, C.armrestTop), size: CGSize(width: m(section.armrest), height: m(C.armrestHeight))),
                                        cornerSize: CGSize(width: m(0.015), height: m(0.015)))
                    arms.move(to: pt(x + section.armrest / 2, C.armrestTop - C.armrestHeight))
                    arms.addLine(to: pt(x + section.armrest / 2, C.cushionTop - 0.02))
                }
                l.fill(arms, with: .color(tint))
                l.stroke(arms, with: .color(stroke), lineWidth: lw * 0.9)
            }
        }

        // The break at the centreline, a zigzag, and the section's centreline.
        var brk = Path()
        let top = c.y - r * 1.02, bottom = min(size.height, c.y + r * 0.95)
        brk.move(to: CGPoint(x: c.x, y: top)); brk.addLine(to: CGPoint(x: c.x, y: c.y - 0.05 * r))
        brk.addLine(to: CGPoint(x: c.x - 4, y: c.y - 0.02 * r)); brk.addLine(to: CGPoint(x: c.x + 4, y: c.y + 0.02 * r))
        brk.addLine(to: CGPoint(x: c.x, y: c.y + 0.05 * r)); brk.addLine(to: CGPoint(x: c.x, y: bottom))
        ctx.stroke(brk, with: .color(ink.opacity(0.45)), style: StrokeStyle(lineWidth: 0.5, dash: [9, 2, 2, 2]))
    }
}
