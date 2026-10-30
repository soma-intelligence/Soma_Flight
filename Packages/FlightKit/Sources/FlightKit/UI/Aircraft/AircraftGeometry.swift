import CoreGraphics
import Synchronization
import SwiftUI

/// Draw order of a side view, back to front. The far wing, engine and gear sit behind the fuselage;
/// the near ones in front of it.
public enum AircraftLayer: Int, CaseIterable, Sendable {
    case gearFar, wingFar, engineFar, fuselage, windows, doors, wing, engine, tail, gear
}

/// What a path is, so a livery can paint each part on its own: the hull takes the fuselage top, belly
/// and cheatline (clipped to it), the fin the tail paint, the nacelles the engine colour.
public enum AircraftPart: String, CaseIterable, Sendable {
    case hull, fairing, panelLine, fin, tailplane, wing, flapFairing, winglet, pylon, nacelle, inlet, fan, exhaust, plug
    case window, cockpit, mask, door, cargoDoor, apu, strut, tyre, hub
}

/// One path of a side view with its layer and part.
public struct AircraftShape: Sendable {
    public var layer: AircraftLayer
    public var part: AircraftPart
    public var path: Path
}

/// A side view in metres: x from the nose (0) aft, y from the ground up, nose to the left. Built from
/// the manufacturers' public airport planning dimensions (overall length and height, fuselage
/// diameter, door positions, window pitch), drawn in our own line style.
public struct AircraftGeometry: Sendable {
    public var family: AircraftFamily
    public var lengthM: Double
    public var heightM: Double
    /// Every path, back to front.
    public var shapes: [AircraftShape]
    /// Where a tail logo goes, in metres.
    public var finBox: CGRect
    /// Window band in metres from the ground, where a cheatline runs.
    public var cheatlineBand: ClosedRange<Double>
    /// Where the airline title starts (left end of its baseline), in metres.
    public var titleAnchor: CGPoint
    /// Barrel bottom and top in metres, for a livery's belly split.
    public var fuselageBottomM: Double
    public var fuselageTopM: Double

    public var layers: [AircraftLayer: [Path]] {
        Dictionary(grouping: shapes, by: \.layer).mapValues { $0.map(\.path) }
    }

    /// One path per part (all of that part's paths together), for fills and clips.
    public var parts: [AircraftPart: Path] {
        var out: [AircraftPart: Path] = [:]
        for s in shapes { out[s.part, default: Path()].addPath(s.path) }
        return out
    }

    public static func geometry(_ family: AircraftFamily) -> AircraftGeometry {
        switch family {
        case .a320: return A320Family.geometry(nil)
        case .a350: return A350.geometry(nil)
        case .b737: return B737.geometry(nil)
        case .b737max: return B737Max.geometry(nil)
        case .b777: return B777.geometry(nil)
        case .b787: return B787.geometry(nil)
        default:
            var g = family.isWidebody ? Generic.widebody : Generic.narrowbody
            g.family = family
            return g
        }
    }

    /// The drawing for a type: its own variant's length when the family is drawn, else the family's
    /// default, else the generic body. `nil` gives the generic narrowbody. Built once per family and type
    /// for the process (list rows ask on every redraw).
    public static func geometry(type: AircraftType?) -> AircraftGeometry {
        let key = cacheKey(type)
        if let held = geometryCache.withLock({ $0[key] }) { return held }
        let built = build(type: type)
        geometryCache.withLock { $0[key] = built }
        return built
    }

    /// The cache key of a type's drawing: its family and ICAO id.
    static func cacheKey(_ type: AircraftType?) -> String {
        type.map { "\($0.family.rawValue)/\($0.id.uppercased())" } ?? "-"
    }

    private static func build(type: AircraftType?) -> AircraftGeometry {
        guard let type else { return Generic.narrowbody }
        switch type.family {
        case .a320: return A320Family.geometry(type.id)
        case .a350: return A350.geometry(type.id)
        case .b737: return B737.geometry(type.id)
        case .b737max: return B737Max.geometry(type.id)
        case .b777: return B777.geometry(type.id)
        case .b787: return B787.geometry(type.id)
        default: return geometry(type.family)
        }
    }
}


/// Drawings built so far, by `AircraftGeometry.cacheKey`.
private let geometryCache = Mutex<[String: AircraftGeometry]>([:])

// MARK: - Spec

/// The numbers that make an airliner in profile. Lengths in metres; "from tail" distances are measured
/// forward from the aft end, so a stretch only moves the barrel. The view is from the side and a little
/// below, so the near wing and tailplane show a slim strip of their lower surface.
struct AirlinerSpec {
    enum Nose { case airbus, b737, b777, b787, a350 }
    enum Fin { case swept, dorsal, clipped, curvedLeadingEdge, curvedTip }
    enum Winglet { case none, sharklet, blended, splitScimitar, raked, curled }
    enum EngineStyle { case plain, flatBottom, chevron }

    var family: AircraftFamily
    var length: Double
    var height: Double
    var diameter: Double
    /// Height of the barrel bottom above the ground.
    var bottom: Double
    var nose: Nose
    var noseLength: Double
    var tailLength: Double

    var fin: Fin
    var finRootLEFromTail: Double
    var finRootChord: Double
    var finTipChord: Double
    /// Tip leading edge x minus root leading edge x.
    var finSweep: Double
    var finFillet: Double

    var tailplaneLEFromTail: Double
    var tailplaneChord: Double
    var tailplaneRun: Double
    var tailplaneRise: Double

    /// Wing leading edge where it meets the fuselage side.
    var wingRootLE: Double
    var wingRootChord: Double
    var wingTipChord: Double
    /// Tip leading edge x minus root leading edge x, as seen from the side.
    var wingSweep: Double
    /// How much higher the tip sits than the root in the drawing (dihedral and the view from below).
    var wingRise: Double
    var winglet: Winglet
    var wingletHeight: Double

    var engineDiameter: Double
    var engineLength: Double
    var engineClearance: Double
    /// Inlet x relative to the wing root leading edge (negative: ahead of it).
    var engineInletFromWing: Double
    var engineStyle: EngineStyle

    var noseGearX: Double
    var mainGearX: Double
    var noseTyre: Double
    var mainTyre: Double
    var mainAxles: Int
    var axleSpacing: Double

    var doors: [Door]
    var cargoDoors: [Double]
    var cargoDoorWidth: Double
    var windowPitch: Double
    var windowWidth: Double
    var windowHeight: Double
    /// Window centre line as a fraction of the diameter above the barrel bottom.
    var windowLine: Double
    var firstWindow: Double
    var lastWindowFromTail: Double

    struct Door {
        var x: Double
        var width: Double
        var height: Double
        var overwing = false
    }
}

// MARK: - Builder

/// A cubic Bezier with lookups by x, for following the hull's outline.
struct Cubic {
    var p0, p1, p2, p3: CGPoint

    func point(_ t: Double) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    /// y where the curve crosses x (the curve is monotonic in x where we use this).
    func y(atX x: Double) -> Double {
        var lo = 0.0, hi = 1.0
        let rising = p3.x > p0.x
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if (point(mid).x < x) == rising { lo = mid } else { hi = mid }
        }
        return point((lo + hi) / 2).y
    }
}

private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

private func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

extension AirlinerSpec {
    func build() -> AircraftGeometry {
        var shapes: [AircraftShape] = []
        func add(_ layer: AircraftLayer, _ part: AircraftPart, _ path: Path) {
            shapes.append(AircraftShape(layer: layer, part: part, path: path))
        }
        let L = length, D = diameter, yb = bottom, yt = bottom + diameter, nl = noseLength

        // Hull ----------------------------------------------------------------------------------
        // Nose tip height, upper curve controls (fraction of D up from the tip, fraction of the nose
        // length where the crown is reached), lower curve droop; cockpit panes as fractions of the nose.
        let noseTip: Double, upperK: (Double, Double), lowerK: Double, panes: [(Double, Double)]
        switch nose {
        case .airbus: noseTip = 0.30; upperK = (0.28, 0.45); lowerK = 0.25
            panes = [(0.455, 0.575), (0.59, 0.69), (0.705, 0.79)]
        case .b737: noseTip = 0.29; upperK = (0.22, 0.55); lowerK = 0.21
            panes = [(0.49, 0.60), (0.615, 0.70), (0.715, 0.785)]
        case .b777: noseTip = 0.32; upperK = (0.21, 0.56); lowerK = 0.25
            panes = [(0.37, 0.48), (0.495, 0.58), (0.595, 0.66)]
        case .b787: noseTip = 0.33; upperK = (0.25, 0.60); lowerK = 0.27
            panes = [(0.53, 0.665), (0.68, 0.785)]
        case .a350: noseTip = 0.31; upperK = (0.28, 0.52); lowerK = 0.25
            panes = [(0.50, 0.61), (0.625, 0.715), (0.73, 0.80)]
        }
        let tipY = yb + noseTip * D
        let upperNose = Cubic(p0: p(0, tipY), p1: p(0, tipY + upperK.0 * D), p2: p(nl * upperK.1, yt), p3: p(nl, yt))
        let tipTop = yb + 0.74 * D, tipBottom = yb + 0.61 * D
        let upperTail = Cubic(p0: p(L - tailLength * 0.74, yt), p1: p(L - tailLength * 0.34, yt),
                              p2: p(L - tailLength * 0.07, tipTop + 0.07 * D), p3: p(L, tipTop))
        let lowerTail = Cubic(p0: p(L, tipBottom), p1: p(L - tailLength * 0.40, yb + 0.30 * D),
                              p2: p(L - tailLength * 0.80, yb), p3: p(L - tailLength, yb))
        func topY(_ x: Double) -> Double {
            if x <= nl { return upperNose.y(atX: max(0, x)) }
            if x <= upperTail.p0.x { return yt }
            return upperTail.y(atX: min(x, L))
        }
        func bottomY(_ x: Double) -> Double {
            x >= lowerTail.p3.x ? lowerTail.y(atX: min(x, L)) : yb
        }
        let rootLE = wingRootLE, cr = wingRootChord
        let fairStart = rootLE - cr * 0.18, fairEnd = rootLE + cr * 1.22
        let bulge = D * 0.075

        var hull = Path()
        hull.move(to: p(0, tipY))
        hull.addCurve(to: upperNose.p3, control1: upperNose.p1, control2: upperNose.p2)
        hull.addLine(to: upperTail.p0)
        hull.addCurve(to: upperTail.p3, control1: upperTail.p1, control2: upperTail.p2)
        hull.addLine(to: p(L, tipBottom))
        hull.addCurve(to: lowerTail.p3, control1: lowerTail.p1, control2: lowerTail.p2)
        hull.addLine(to: p(fairEnd, yb))
        hull.addCurve(to: p(fairStart, yb), control1: p(fairEnd - (fairEnd - fairStart) * 0.22, yb - bulge * 1.33),
                      control2: p(fairStart + (fairEnd - fairStart) * 0.18, yb - bulge * 1.33))
        hull.addLine(to: p(nl * 0.85, yb))
        hull.addCurve(to: p(0, tipY), control1: p(nl * 0.32, yb), control2: p(0, tipY - lowerK * D))
        hull.closeSubpath()
        add(.fuselage, .hull, hull)

        // APU exhaust at the tail cone.
        let apuH = (tipTop - tipBottom) * 0.55
        add(.fuselage, .apu, Path(ellipseIn: CGRect(x: L - 0.08, y: (tipTop + tipBottom - apuH) / 2, width: 0.08, height: apuH)))

        // Panel lines: the section joints, very faint.
        for x in [nl * 1.02, rootLE - cr * 0.12, rootLE + cr * 1.05, L - tailLength * 0.98] {
            var line = Path()
            line.move(to: p(x, bottomY(x) + 0.03 * D))
            line.addLine(to: p(x, topY(x) - 0.02 * D))
            add(.doors, .panelLine, line)
        }

        // Cockpit: a thin band of panes following the nose curve, posts between them.
        let bandTop = 0.040 * D, bandBottom = 0.130 * D
        func pane(_ x0: Double, _ x1: Double, front: Bool, aft: Bool) -> Path {
            var path = Path()
            let h0 = bandBottom - bandTop
            path.move(to: p(front ? x0 + h0 * 0.9 : x0, topY(x0) - bandBottom))
            path.addLine(to: p(x0, topY(x0) - bandTop))
            for i in 1...6 {
                let x = x0 + (x1 - x0) * Double(i) / 6
                path.addLine(to: p(x, topY(x) - bandTop))
            }
            path.addLine(to: p(aft ? x1 - h0 * 0.7 : x1, topY(x1) - bandBottom))
            for i in (1...5).reversed() {
                let x = x0 + (x1 - x0) * Double(i) / 6
                if !aft || x < x1 - h0 * 0.7 { path.addLine(to: p(x, topY(x) - bandBottom)) }
            }
            path.closeSubpath()
            return path
        }
        if nose == .a350 {
            // The "panda mask": a black surround from the windscreen back past the side windows, its aft end
            // drawn back to a rounded point.
            let m0 = nl * 0.46, m1 = nl * 0.86
            var mask = Path()
            mask.move(to: p(m0 + 0.06 * D, topY(m0) - bandBottom - 0.03 * D))
            mask.addLine(to: p(m0 - 0.015 * D, topY(m0) - bandTop + 0.022 * D))
            for i in 1...10 {
                let x = m0 + (m1 - m0) * Double(i) / 10
                mask.addLine(to: p(x, topY(x) - bandTop + 0.022 * D))
            }
            mask.addCurve(to: p(m1 + 0.13 * D, topY(m1) - 0.10 * D), control1: p(m1 + 0.06 * D, topY(m1) - bandTop + 0.02 * D),
                          control2: p(m1 + 0.12 * D, topY(m1) - 0.07 * D))
            mask.addCurve(to: p(m1 - 0.02 * D, topY(m1) - bandBottom - 0.03 * D), control1: p(m1 + 0.13 * D, topY(m1) - 0.13 * D),
                          control2: p(m1 + 0.06 * D, topY(m1) - bandBottom - 0.03 * D))
            for i in (1...9).reversed() {
                let x = m0 + (m1 - m0) * Double(i) / 10
                mask.addLine(to: p(x, topY(x) - bandBottom - 0.03 * D))
            }
            mask.closeSubpath()
            add(.windows, .mask, mask)
        }
        for (i, pn) in panes.enumerated() {
            add(.windows, .cockpit, pane(nl * pn.0, nl * pn.1, front: i == 0, aft: i == panes.count - 1))
        }

        // Cabin windows and doors ------------------------------------------------------------------
        let windowY = yb + windowLine * D
        for door in doors {
            if door.overwing {
                add(.doors, .door, Path(roundedRect: CGRect(x: door.x - door.width / 2, y: windowY - door.height * 0.55,
                                                            width: door.width, height: door.height), cornerRadius: 0.12))
            } else {
                let top = windowY + windowHeight * 0.5 + 0.28
                add(.doors, .door, Path(roundedRect: CGRect(x: door.x - door.width / 2, y: top - door.height,
                                                            width: door.width, height: door.height), cornerRadius: 0.14))
            }
        }
        for x in cargoDoors {
            add(.doors, .cargoDoor, Path(roundedRect: CGRect(x: x - cargoDoorWidth / 2, y: yb + 0.10 * D,
                                                             width: cargoDoorWidth, height: D * 0.25), cornerRadius: 0.12))
        }
        var wx = firstWindow
        while wx <= L - lastWindowFromTail {
            let blocked = doors.contains { abs($0.x - wx) < $0.width / 2 + windowWidth * 0.9 }
            if !blocked {
                add(.windows, .window, Path(roundedRect: CGRect(x: wx - windowWidth / 2, y: windowY - windowHeight / 2,
                                                                width: windowWidth, height: windowHeight),
                                            cornerRadius: windowWidth * 0.42))
            }
            wx += windowPitch
        }

        // Fin ----------------------------------------------------------------------------------
        let finRootLE = L - finRootLEFromTail
        let finRootTE = finRootLE + finRootChord
        let finTipLE = finRootLE + finSweep
        let finTipTE = finTipLE + finTipChord
        let finBaseY = topY(finRootLE)
        let finH = height - finBaseY
        let root = p(finRootLE, finBaseY), tip = p(finTipLE, height)
        let filletStart = finRootLE - finFillet
        var finPath = Path()
        finPath.move(to: p(filletStart, topY(filletStart)))
        switch self.fin {
        case .curvedLeadingEdge:
            // One sweep from the fillet into the leading edge, no corner.
            finPath.addCurve(to: lerp(root, tip, 0.96), control1: p(finRootLE - finFillet * 0.05, finBaseY + 0.03 * finH),
                         control2: lerp(root, tip, 0.42))
        case .dorsal:
            // The 737's long, low dorsal fin running forward along the crown.
            finPath.addCurve(to: lerp(root, tip, 0.30), control1: p(finRootLE - finFillet * 0.55, topY(finRootLE - finFillet * 0.55) + 0.05 * finH),
                         control2: p(finRootLE - finFillet * 0.05, finBaseY + 0.15 * finH))
            finPath.addLine(to: lerp(root, tip, 0.96))
        default:
            finPath.addCurve(to: lerp(root, tip, 0.20), control1: p(finRootLE - finFillet * 0.35, topY(finRootLE - finFillet * 0.35) + 0.02 * finH),
                         control2: lerp(root, tip, 0.07))
            finPath.addLine(to: lerp(root, tip, self.fin == .clipped ? 0.985 : 0.96))
        }
        let teAt = { (f: Double) in lerp(p(finRootTE, topY(finRootTE)), p(finTipTE, height), f) }
        switch self.fin {
        case .curvedTip:
            // A350: the tip rounds down into the trailing edge.
            finPath.addQuadCurve(to: p(finTipLE + finTipChord * 0.10, height), control: tip)
            finPath.addLine(to: p(finTipLE + finTipChord * 0.45, height))
            finPath.addCurve(to: teAt(0.80), control1: p(finTipTE + finTipChord * 0.05, height),
                         control2: lerp(teAt(0.80), teAt(1), 0.55))
        case .clipped:
            finPath.addQuadCurve(to: p(finTipLE + finTipChord * 0.04, height), control: tip)
            finPath.addLine(to: p(finTipTE, height))
        default:
            finPath.addQuadCurve(to: p(finTipLE + finTipChord * 0.12, height), control: tip)
            finPath.addLine(to: p(finTipTE - finTipChord * 0.06, height))
            finPath.addQuadCurve(to: teAt(0.985), control: p(finTipTE, height))
        }
        finPath.addLine(to: p(finRootTE, topY(finRootTE)))
        for i in 1...20 {
            let xx = finRootTE - (finRootTE - filletStart) * Double(i) / 20
            finPath.addLine(to: p(xx, topY(xx)))
        }
        finPath.closeSubpath()
        add(.tail, .fin, finPath)
        // Rudder hinge line.
        var rudder = Path()
        rudder.move(to: lerp(p(finRootTE, topY(finRootTE)), p(finRootLE, finBaseY), 0.30))
        rudder.addLine(to: lerp(p(finTipTE, height), tip, 0.32))
        add(.tail, .panelLine, rudder)

        // Tailplane: slim swept strip from the tail cone, its lower surface just showing.
        let tpLE = L - tailplaneLEFromTail
        let tpZ = yb + 0.60 * D
        let tpTipChord = tailplaneChord * 0.36
        let tpRun = min(tailplaneRun, L - 0.25 - tpLE - tpTipChord)
        let tpA = p(tpLE, tpZ), tpB = p(tpLE + tpRun, tpZ + tailplaneRise)
        let tpC = p(tpLE + tpRun + tpTipChord, tpZ + tailplaneRise - 0.035 * D)
        let tpE = p(tpLE + tailplaneChord, tpZ - 0.11 * D)
        var tailplane = Path()
        tailplane.move(to: tpA)
        tailplane.addCurve(to: tpB, control1: lerp(tpA, tpB, 0.35), control2: lerp(tpA, tpB, 0.75))
        tailplane.addQuadCurve(to: tpC, control: p(tpB.x + tpTipChord * 0.6, tpB.y + 0.005 * D))
        tailplane.addLine(to: tpE)
        tailplane.addCurve(to: tpA, control1: p(tpE.x - tailplaneChord * 0.45, tpE.y - 0.01 * D),
                           control2: p(tpA.x + tailplaneChord * 0.08, tpA.y - 0.08 * D))
        tailplane.closeSubpath()
        add(.tail, .tailplane, tailplane)
        var elevator = Path()
        elevator.move(to: lerp(tpE, tpA, 0.30))
        elevator.addLine(to: lerp(tpC, tpB, 0.30))
        add(.tail, .panelLine, elevator)

        // Wing -----------------------------------------------------------------------------------
        let zr = yb + 0.30 * D
        let tipLE = rootLE + wingSweep
        let zt = zr + wingRise
        let depthRoot = (D > 5 ? 0.24 : 0.19) * D, depthTip = max(0.10, 0.035 * D)
        let wa = p(rootLE, zr), wb = p(tipLE, zt)
        let wc = p(tipLE + wingTipChord, zt - depthTip)
        let rootTE = p(rootLE + cr, zr - depthRoot * 0.75)
        // Trailing edge kink: unswept inboard, swept outboard.
        let kinkF = 0.32
        let wk = p(rootTE.x + wingSweep * kinkF * 0.30, zr + wingRise * kinkF - depthRoot * 0.62)
        func leZ(_ x: Double) -> Double { zr + wingRise * min(1, max(0, (x - rootLE) / wingSweep)) }

        func wingPath(dx: Double, dy: Double) -> Path {
            func q(_ pt: CGPoint) -> CGPoint { p(pt.x + dx, pt.y + dy) }
            var w = Path()
            w.move(to: q(wa))
            w.addCurve(to: q(wb), control1: q(lerp(wa, wb, 0.33)), control2: q(p(lerp(wa, wb, 0.7).x, lerp(wa, wb, 0.7).y + 0.01 * D)))
            w.addLine(to: q(wc))
            w.addCurve(to: q(wk), control1: q(lerp(wc, wk, 0.4)), control2: q(lerp(wc, wk, 0.8)))
            w.addQuadCurve(to: q(rootTE), control: q(p(wk.x - (wk.x - rootTE.x) * 0.4, rootTE.y + 0.02 * D)))
            // Inboard: the lower surface running back into the belly fairing.
            w.addCurve(to: q(wa), control1: q(p(rootLE + cr * 0.55, zr - depthRoot * 1.02)),
                       control2: q(p(rootLE + cr * 0.06, zr - depthRoot * 0.55)))
            w.closeSubpath()
            return w
        }
        add(.wingFar, .wing, wingPath(dx: wingSweep * 0.03, dy: 0.12 * D))

        // Wing-to-body fairing: the rounded fairing the wing root sits in, over the belly bulge.
        var fairing = Path()
        fairing.move(to: p(fairStart - cr * 0.06, yb + 0.02 * D))
        fairing.addCurve(to: p(rootLE + cr * 0.12, zr + 0.06 * D), control1: p(fairStart, yb + 0.20 * D),
                         control2: p(rootLE - cr * 0.02, zr + 0.06 * D))
        fairing.addLine(to: p(rootLE + cr * 0.92, zr - 0.04 * D))
        fairing.addCurve(to: p(fairEnd, yb), control1: p(fairEnd - cr * 0.05, zr - 0.06 * D), control2: p(fairEnd, yb + 0.10 * D))
        fairing.addCurve(to: p(fairStart, yb), control1: p(fairEnd - (fairEnd - fairStart) * 0.22, yb - bulge * 1.33),
                         control2: p(fairStart + (fairEnd - fairStart) * 0.18, yb - bulge * 1.33))
        fairing.closeSubpath()
        add(.wing, .fairing, fairing)

        add(.wing, .wing, wingPath(dx: 0, dy: 0))
        // Slat line just behind the leading edge, flap line ahead of the trailing edge.
        var slat = Path()
        slat.move(to: p(rootLE + 0.5, leZ(rootLE + 0.5) - 0.035 * D))
        slat.addLine(to: p(tipLE - 0.2, zt - 0.02 * D))
        add(.wing, .panelLine, slat)
        var flap = Path()
        flap.move(to: p(rootTE.x - cr * 0.18, rootTE.y + 0.05 * D))
        flap.addLine(to: p(wk.x - cr * 0.12, wk.y + 0.04 * D))
        flap.addLine(to: p(wc.x - wingTipChord * 0.45, wc.y + 0.012 * D))
        add(.wing, .panelLine, flap)

        // Flap track fairings: small pods hanging under the trailing edge, pointed aft.
        let pods: [Double] = family.isWidebody || family == .other && D > 5 ? [0.18, 0.40, 0.60, 0.78] : [0.22, 0.48, 0.74]
        for f in pods {
            let te = f < kinkF ? lerp(rootTE, wk, f / kinkF) : lerp(wk, wc, (f - kinkF) / (1 - kinkF))
            let chord = cr + (wingTipChord - cr) * f
            let len = chord * 0.30 + D * 0.12, h = D * 0.055
            let x0 = te.x - len * 0.55, z0 = te.y + 0.005 * D
            // A canoe under the trailing edge: rounded nose, deepest a third along, tapering aft.
            var pod = Path()
            pod.move(to: p(x0, z0))
            pod.addCurve(to: p(x0 + len, z0 - h * 0.35), control1: p(x0 + len * 0.05, z0 - h * 1.25),
                         control2: p(x0 + len * 0.6, z0 - h * 1.1))
            pod.addQuadCurve(to: p(x0 + len * 0.45, z0 + 0.004 * D), control: p(x0 + len * 0.85, z0 + 0.004 * D))
            pod.closeSubpath()
            add(.wing, .flapFairing, pod)
        }
        if let tipDevice = wingletPath(tipLE: tipLE, tipTE: tipLE + wingTipChord, tipZ: zt - depthTip * 0.5, thick: depthTip) {
            add(.wing, .winglet, tipDevice)
        }

        // Engines ---------------------------------------------------------------------------------
        let eX = rootLE + engineInletFromWing
        let eZ = engineClearance + engineDiameter / 2
        func engine(dx: Double, dy: Double, layer: AircraftLayer) {
            let d = engineDiameter, l = engineLength, x0 = eX + dx, z = eZ + dy
            let flat = engineStyle == .flatBottom
            let fanLen = l * (d > 3.6 ? 0.66 : 0.62)
            let cowlEnd = x0 + fanLen
            let low = flat ? 0.42 : 0.49
            let nozzleR = 0.39 * d, nozzleLow = flat ? 0.33 * d : 0.39 * d

            // Pylon up into the wing's lower surface.
            var pylon = Path()
            pylon.move(to: p(x0 + l * 0.14, z + 0.47 * d))
            pylon.addLine(to: p(x0 + l * 0.30, max(z + 0.5 * d, leZ(x0 + l * 0.30) - 0.03 * D) + dy * 0))
            pylon.addLine(to: p(x0 + l * 0.98, max(z + 0.38 * d, leZ(x0 + l * 0.98) - 0.10 * D)))
            pylon.addQuadCurve(to: p(x0 + l * 0.84, z + 0.17 * d), control: p(x0 + l * 0.95, z + 0.24 * d))
            pylon.closeSubpath()
            add(layer, .pylon, pylon)

            // Core cowl and exhaust plug behind the fan cowl.
            let coreEnd = x0 + l * 0.86
            var core = Path()
            core.move(to: p(cowlEnd - 0.1, z + 0.31 * d))
            core.addCurve(to: p(coreEnd, z + 0.18 * d), control1: p(cowlEnd + l * 0.10, z + 0.30 * d), control2: p(coreEnd - l * 0.08, z + 0.21 * d))
            core.addLine(to: p(coreEnd, z - 0.16 * d))
            core.addCurve(to: p(cowlEnd - 0.1, z - (flat ? 0.27 : 0.30) * d), control1: p(coreEnd - l * 0.08, z - 0.20 * d),
                          control2: p(cowlEnd + l * 0.10, z - 0.28 * d))
            core.closeSubpath()
            add(layer, .exhaust, core)
            var plug = Path()
            plug.move(to: p(coreEnd - 0.05, z + 0.13 * d))
            plug.addQuadCurve(to: p(x0 + l, z - 0.01 * d), control: p(coreEnd + l * 0.08, z + 0.10 * d))
            plug.addQuadCurve(to: p(coreEnd - 0.05, z - 0.12 * d), control: p(coreEnd + l * 0.08, z - 0.08 * d))
            plug.closeSubpath()
            add(layer, .plug, plug)

            // Fan cowl.
            var n = Path()
            n.move(to: p(x0 + 0.02 * d, z + 0.47 * d))
            n.addCurve(to: p(cowlEnd, z + nozzleR), control1: p(x0 + l * 0.24, z + 0.54 * d), control2: p(x0 + l * 0.48, z + 0.50 * d))
            if engineStyle == .chevron {
                let teeth = 8
                let span = nozzleR + nozzleLow
                for i in 0..<teeth {
                    let mid = z + nozzleR - span * (Double(i) + 0.5) / Double(teeth)
                    n.addLine(to: p(cowlEnd + l * 0.022, mid))
                    n.addLine(to: p(cowlEnd, z + nozzleR - span * Double(i + 1) / Double(teeth)))
                }
            } else {
                n.addQuadCurve(to: p(cowlEnd, z - nozzleLow), control: p(cowlEnd + l * 0.012, z))
            }
            n.addCurve(to: p(x0 + 0.02 * d, z - (low - 0.02) * d), control1: p(x0 + l * 0.48, z - (low + 0.01) * d),
                       control2: p(x0 + l * 0.24, z - (low + 0.04) * d))
            n.addCurve(to: p(x0 + 0.02 * d, z + 0.47 * d), control1: p(x0 - 0.06 * d, z - 0.22 * d), control2: p(x0 - 0.06 * d, z + 0.30 * d))
            n.closeSubpath()
            add(layer, .nacelle, n)

            // Inlet lip (bright crescent) and the fan face just showing behind it.
            var lip = Path()
            lip.move(to: p(x0 + 0.02 * d, z + 0.47 * d))
            lip.addCurve(to: p(x0 + 0.02 * d, z - (low - 0.02) * d), control1: p(x0 - 0.06 * d, z + 0.30 * d), control2: p(x0 - 0.06 * d, z - 0.22 * d))
            lip.addCurve(to: p(x0 + 0.02 * d, z + 0.47 * d), control1: p(x0 + 0.03 * d, z - 0.22 * d), control2: p(x0 + 0.03 * d, z + 0.30 * d))
            lip.closeSubpath()
            add(layer, .inlet, lip)
            var fan = Path()
            fan.move(to: p(x0 + 0.05 * d, z + 0.40 * d))
            fan.addCurve(to: p(x0 + 0.05 * d, z - (low - 0.08) * d), control1: p(x0 + 0.035 * d, z + 0.2 * d), control2: p(x0 + 0.035 * d, z - 0.2 * d))
            fan.addCurve(to: p(x0 + 0.05 * d, z + 0.40 * d), control1: p(x0 + 0.075 * d, z - 0.2 * d), control2: p(x0 + 0.075 * d, z + 0.2 * d))
            fan.closeSubpath()
            add(layer, .fan, fan)
        }
        engine(dx: wingSweep * 0.03, dy: 0.10 * D, layer: .engineFar)
        engine(dx: 0, dy: 0, layer: .engine)

        // Gear ----------------------------------------------------------------------------------
        func gear(dx: Double, layer: AircraftLayer, near: Bool) {
            let nx = noseGearX + dx
            add(layer, .strut, Path(roundedRect: CGRect(x: nx - 0.08, y: noseTyre, width: 0.16, height: yb - noseTyre + 0.05),
                                    cornerRadius: 0.05))
            add(layer, .tyre, Path(ellipseIn: CGRect(x: nx - noseTyre, y: 0, width: noseTyre * 2, height: noseTyre * 2)))
            if near { add(layer, .hub, Path(ellipseIn: CGRect(x: nx - noseTyre * 0.42, y: noseTyre * 0.58, width: noseTyre * 0.84, height: noseTyre * 0.84))) }
            let mx = mainGearX + dx
            let span = axleSpacing * Double(mainAxles - 1)
            let legTop = zr - depthRoot * 0.6
            add(layer, .strut, Path(roundedRect: CGRect(x: mx - 0.13, y: mainTyre, width: 0.26, height: legTop - mainTyre),
                                    cornerRadius: 0.07))
            // Side brace from the leg up and forward into the wing.
            var brace = Path()
            brace.move(to: p(mx - 0.05, mainTyre + (legTop - mainTyre) * 0.55))
            brace.addLine(to: p(mx - (legTop - mainTyre) * 0.35, legTop))
            brace.addLine(to: p(mx - (legTop - mainTyre) * 0.35 + 0.12, legTop))
            brace.addLine(to: p(mx + 0.05, mainTyre + (legTop - mainTyre) * 0.55 + 0.1))
            brace.closeSubpath()
            add(layer, .strut, brace)
            if mainAxles > 1 {
                add(layer, .strut, Path(roundedRect: CGRect(x: mx - span / 2 - 0.1, y: mainTyre - 0.09, width: span + 0.2, height: 0.18),
                                        cornerRadius: 0.09))
            }
            for i in 0..<mainAxles {
                let cx = mx - span / 2 + axleSpacing * Double(i)
                add(layer, .tyre, Path(ellipseIn: CGRect(x: cx - mainTyre, y: 0, width: mainTyre * 2, height: mainTyre * 2)))
                if near { add(layer, .hub, Path(ellipseIn: CGRect(x: cx - mainTyre * 0.42, y: mainTyre * 0.58, width: mainTyre * 0.84, height: mainTyre * 0.84))) }
            }
        }
        gear(dx: 0.3, layer: .gearFar, near: false)
        gear(dx: 0, layer: .gear, near: true)

        // Slots ---------------------------------------------------------------------------------
        let midY = finBaseY + finH * 0.52
        let midLE = finRootLE + finSweep * 0.52, midTE = finRootTE + (finTipTE - finRootTE) * 0.52
        let chord = midTE - midLE
        let finBox = CGRect(x: midLE + chord * 0.16, y: midY - finH * 0.27, width: chord * 0.62, height: finH * 0.54)
        let band = (windowY - windowHeight * 0.9)...(windowY + windowHeight * 0.9)
        let anchor = CGPoint(x: firstWindow + windowPitch * 2, y: windowY + windowHeight * 0.75)
        return AircraftGeometry(family: family, lengthM: length, heightM: height, shapes: shapes, finBox: finBox,
                                cheatlineBand: band, titleAnchor: anchor, fuselageBottomM: yb, fuselageTopM: yt)
    }

    /// The wing tip device in profile, rising from the tip chord.
    private func wingletPath(tipLE: Double, tipTE: Double, tipZ: Double, thick: Double) -> Path? {
        let c = tipTE - tipLE, h = wingletHeight
        var w = Path()
        switch winglet {
        case .none:
            return nil
        case .sharklet:
            // Airbus sharklet: a smooth blend from the tip into a tall swept fin.
            w.move(to: p(tipLE - c * 0.15, tipZ + thick * 0.5))
            w.addCurve(to: p(tipLE + c * 1.0, tipZ + h), control1: p(tipLE + c * 0.4, tipZ + thick * 0.6), control2: p(tipLE + c * 0.72, tipZ + h * 0.45))
            w.addLine(to: p(tipLE + c * 1.30, tipZ + h))
            w.addCurve(to: p(tipTE, tipZ - thick * 0.5), control1: p(tipLE + c * 1.18, tipZ + h * 0.5), control2: p(tipTE + c * 0.08, tipZ + h * 0.12))
            w.closeSubpath()
        case .blended:
            // 737NG blended winglet: a long sweep with a large root radius.
            w.move(to: p(tipLE - c * 0.1, tipZ + thick * 0.5))
            w.addCurve(to: p(tipLE + c * 1.2, tipZ + h), control1: p(tipLE + c * 0.6, tipZ + thick * 0.5), control2: p(tipLE + c * 0.9, tipZ + h * 0.55))
            w.addLine(to: p(tipLE + c * 1.5, tipZ + h))
            w.addCurve(to: p(tipTE, tipZ - thick * 0.5), control1: p(tipLE + c * 1.35, tipZ + h * 0.45), control2: p(tipTE + c * 0.12, tipZ + h * 0.08))
            w.closeSubpath()
        case .splitScimitar:
            // 737 MAX: the upper scimitar plus a ventral blade pointing down and aft.
            w.move(to: p(tipLE - c * 0.1, tipZ + thick * 0.5))
            w.addCurve(to: p(tipLE + c * 1.15, tipZ + h), control1: p(tipLE + c * 0.55, tipZ + thick * 0.5), control2: p(tipLE + c * 0.85, tipZ + h * 0.55))
            w.addLine(to: p(tipLE + c * 1.42, tipZ + h * 1.02))
            w.addCurve(to: p(tipTE, tipZ), control1: p(tipLE + c * 1.28, tipZ + h * 0.45), control2: p(tipTE + c * 0.1, tipZ + h * 0.08))
            w.addLine(to: p(tipLE + c * 1.6, tipZ - h * 0.48))
            w.addLine(to: p(tipLE + c * 1.36, tipZ - h * 0.47))
            w.addCurve(to: p(tipLE + c * 0.15, tipZ - thick * 0.5), control1: p(tipLE + c * 0.8, tipZ - h * 0.22), control2: p(tipLE + c * 0.4, tipZ - thick * 0.5))
            w.closeSubpath()
        case .raked:
            // Raked tip: the tip runs on aft to a point instead of rising.
            w.move(to: p(tipLE - c * 0.05, tipZ + thick * 0.5))
            w.addCurve(to: p(tipTE + c * 1.8, tipZ + h), control1: p(tipLE + c * 0.9, tipZ + thick * 0.5 + h * 0.1), control2: p(tipTE + c * 1.2, tipZ + h * 0.75))
            w.addCurve(to: p(tipTE - c * 0.25, tipZ - thick * 0.5), control1: p(tipTE + c * 1.1, tipZ + h * 0.25), control2: p(tipTE + c * 0.4, tipZ - thick * 0.5))
            w.closeSubpath()
        case .curled:
            // A350: the tip curls up and aft in one sweep.
            w.move(to: p(tipLE - c * 0.25, tipZ + thick * 0.5))
            w.addCurve(to: p(tipLE + c * 1.55, tipZ + h), control1: p(tipLE + c * 0.75, tipZ + thick * 0.5), control2: p(tipLE + c * 1.3, tipZ + h * 0.4))
            w.addQuadCurve(to: p(tipLE + c * 1.80, tipZ + h * 0.95), control: p(tipLE + c * 1.72, tipZ + h * 1.03))
            w.addCurve(to: p(tipTE, tipZ - thick * 0.5), control1: p(tipLE + c * 1.6, tipZ + h * 0.35), control2: p(tipTE + c * 0.25, tipZ + h * 0.04))
            w.closeSubpath()
        }
        return w
    }
}
