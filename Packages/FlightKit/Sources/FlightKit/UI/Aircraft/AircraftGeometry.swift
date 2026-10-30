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
    case propeller, spinner
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
        case .a220: return A220.geometry(nil)
        case .a330: return A330.geometry(nil)
        case .a380: return A380.geometry(nil)
        case .b747: return B747.geometry(nil)
        case .b757: return B757.geometry(nil)
        case .b767: return B767.geometry(nil)
        case .ejet: return EJet.geometry(nil)
        case .crj: return CRJ.geometry(nil)
        case .atr: return ATR.geometry(nil)
        case .other:
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
        case .a220: return A220.geometry(type.id)
        case .a330: return A330.geometry(type.id)
        case .a380: return A380.geometry(type.id)
        case .b747: return B747.geometry(type.id)
        case .b757: return B757.geometry(type.id)
        case .b767: return B767.geometry(type.id)
        case .ejet: return EJet.geometry(type.id)
        case .crj: return CRJ.geometry(type.id)
        case .atr: return ATR.geometry(type.id)
        case .other: return geometry(type.family)
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
    enum Nose { case airbus, b737, b777, b787, a350, a220, a380, b747, b757, ejet, crj, atr }
    enum Fin { case swept, dorsal, clipped, curvedLeadingEdge, curvedTip }
    enum Winglet { case none, sharklet, blended, splitScimitar, raked, curled, canted, fence }
    /// `longDuct`: the fan cowl runs nearly to the nozzle (757's RB211-535).
    enum EngineStyle { case plain, flatBottom, chevron, longDuct }
    /// Low wing under the barrel, or high wing on the crown (turboprops).
    enum WingMount { case low, high }
    /// Jets under the wing, jets on the aft fuselage, or turboprops under a high wing.
    enum EngineMount { case wing, rear, turboprop }

    /// The 747's upper deck: the crown rises `rise` above the barrel from the nose back to `end`, then
    /// fairs down over `fair` metres.
    struct Hump { var rise: Double; var end: Double; var fair: Double }

    /// A second row of windows (A380 upper deck, 747 hump): centre line height above the ground and the
    /// run of windows.
    struct UpperDeck { var windowY: Double; var firstWindow: Double; var lastWindow: Double }

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
        /// On the upper deck (window line `upperDeck.windowY`).
        var upper = false
    }

    // Options for the families beyond the underwing twins; the defaults draw a low-wing twin jet.
    var wingMount: WingMount = .low
    var engineMount: EngineMount = .wing
    /// A second engine on each wing, outboard of the first (A380, 747): inlet x from the wing root leading
    /// edge and clearance above the ground.
    var outboardEngine: (inletFromWing: Double, clearance: Double)? = nil
    /// Rear-mounted engines: inlet x measured forward from the aft end, nacelle centre as a fraction of the
    /// diameter above the barrel bottom.
    var rearEngineInletFromTail: Double = 0
    var rearEngineLine: Double = 0.78
    /// Tailplane on top of the fin.
    var tTail = false
    var hump: Hump? = nil
    var upperDeck: UpperDeck? = nil
    /// A second main gear leg (747 and A380 wing gear), its x relative to `mainGearX` and its axle count.
    var wingGear: (dx: Double, axles: Int)? = nil
    var propellerDiameter: Double = 0
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
        let high = wingMount == .high

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
        case .a220: noseTip = 0.30; upperK = (0.30, 0.50); lowerK = 0.24
            panes = [(0.46, 0.585), (0.60, 0.70), (0.715, 0.80)]
        case .a380: noseTip = 0.27; upperK = (0.36, 0.56); lowerK = 0.30
            panes = [(0.20, 0.30), (0.312, 0.39), (0.402, 0.46)]
        case .b747: noseTip = 0.29; upperK = (0.30, 0.42); lowerK = 0.25
            panes = [(0.47, 0.555), (0.567, 0.635), (0.647, 0.70)]
        case .b757: noseTip = 0.29; upperK = (0.22, 0.58); lowerK = 0.22
            panes = [(0.50, 0.61), (0.625, 0.71), (0.725, 0.79)]
        case .ejet: noseTip = 0.29; upperK = (0.28, 0.50); lowerK = 0.24
            panes = [(0.47, 0.60), (0.615, 0.715), (0.73, 0.81)]
        case .crj: noseTip = 0.27; upperK = (0.18, 0.62); lowerK = 0.19
            panes = [(0.54, 0.655), (0.67, 0.75), (0.765, 0.83)]
        case .atr: noseTip = 0.31; upperK = (0.26, 0.50); lowerK = 0.32
            panes = [(0.47, 0.60), (0.615, 0.72), (0.735, 0.82)]
        }
        let tipY = yb + noseTip * D
        // The crown the nose climbs to: the barrel top, or the 747's upper deck.
        let crown = yt + (hump?.rise ?? 0)
        let upperNose = Cubic(p0: p(0, tipY), p1: p(0, tipY + upperK.0 * D), p2: p(nl * upperK.1, crown), p3: p(nl, crown))
        let humpDown = hump.map { h in
            Cubic(p0: p(h.end, crown), p1: p(h.end + h.fair * 0.5, crown), p2: p(h.end + h.fair * 0.5, yt), p3: p(h.end + h.fair, yt))
        }
        let tipTop = yb + 0.74 * D, tipBottom = yb + 0.61 * D
        let upperTail = Cubic(p0: p(L - tailLength * 0.74, yt), p1: p(L - tailLength * 0.34, yt),
                              p2: p(L - tailLength * 0.07, tipTop + 0.07 * D), p3: p(L, tipTop))
        let lowerTail = Cubic(p0: p(L, tipBottom), p1: p(L - tailLength * 0.40, yb + 0.30 * D),
                              p2: p(L - tailLength * 0.80, yb), p3: p(L - tailLength, yb))
        let rootLE = wingRootLE, cr = wingRootChord
        // A high wing sits in a fairing on the crown.
        let dorsal: Cubic? = high ? {
            let a = rootLE - cr * 0.55, b = rootLE + cr * 1.65, rise = 0.16 * D
            return Cubic(p0: p(a, yt), p1: p(a + (b - a) * 0.22, yt + rise * 1.33), p2: p(b - (b - a) * 0.40, yt + rise * 1.33), p3: p(b, yt))
        }() : nil
        func topY(_ x: Double) -> Double {
            if x <= nl { return upperNose.y(atX: max(0, x)) }
            if let h = hump, let down = humpDown {
                if x <= h.end { return crown }
                if x <= down.p3.x { return down.y(atX: x) }
            }
            if let dorsal, x > dorsal.p0.x, x < dorsal.p3.x { return dorsal.y(atX: x) }
            if x <= upperTail.p0.x { return yt }
            return upperTail.y(atX: min(x, L))
        }
        func bottomY(_ x: Double) -> Double {
            x >= lowerTail.p3.x ? lowerTail.y(atX: min(x, L)) : yb
        }
        let fairStart = rootLE - cr * 0.18, fairEnd = rootLE + cr * 1.22
        // The belly bulges under the wing box, or under the main gear sponsons on a high wing.
        let bellyStart = high ? mainGearX - 2.4 : fairStart, bellyEnd = high ? mainGearX + 2.2 : fairEnd
        let bulge = D * (high ? 0.06 : 0.075)

        var hull = Path()
        hull.move(to: p(0, tipY))
        hull.addCurve(to: upperNose.p3, control1: upperNose.p1, control2: upperNose.p2)
        if let down = humpDown {
            hull.addLine(to: down.p0)
            hull.addCurve(to: down.p3, control1: down.p1, control2: down.p2)
        }
        if let dorsal {
            hull.addLine(to: dorsal.p0)
            hull.addCurve(to: dorsal.p3, control1: dorsal.p1, control2: dorsal.p2)
        }
        hull.addLine(to: upperTail.p0)
        hull.addCurve(to: upperTail.p3, control1: upperTail.p1, control2: upperTail.p2)
        hull.addLine(to: p(L, tipBottom))
        hull.addCurve(to: lowerTail.p3, control1: lowerTail.p1, control2: lowerTail.p2)
        hull.addLine(to: p(bellyEnd, yb))
        hull.addCurve(to: p(bellyStart, yb), control1: p(bellyEnd - (bellyEnd - bellyStart) * 0.22, yb - bulge * 1.33),
                      control2: p(bellyStart + (bellyEnd - bellyStart) * 0.18, yb - bulge * 1.33))
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
        // The A380's cockpit sits between the decks, under the upper deck's brow: its band follows the nose
        // curve some way below the outline.
        let paneDrop = nose == .a380 ? 0.17 * D : 0
        for (i, pn) in panes.enumerated() {
            let band = pane(nl * pn.0, nl * pn.1, front: i == 0, aft: i == panes.count - 1)
            add(.windows, .cockpit, paneDrop == 0 ? band : band.applying(CGAffineTransform(translationX: 0, y: -paneDrop)))
        }

        // Cabin windows and doors ------------------------------------------------------------------
        let windowY = yb + windowLine * D
        let upperY = upperDeck?.windowY ?? windowY
        for door in doors {
            let line = door.upper ? upperY : windowY
            if door.overwing {
                add(.doors, .door, Path(roundedRect: CGRect(x: door.x - door.width / 2, y: line - door.height * 0.55,
                                                            width: door.width, height: door.height), cornerRadius: 0.12))
            } else {
                let top = line + windowHeight * 0.5 + 0.28
                add(.doors, .door, Path(roundedRect: CGRect(x: door.x - door.width / 2, y: top - door.height,
                                                            width: door.width, height: door.height), cornerRadius: 0.14))
            }
        }
        for x in cargoDoors {
            add(.doors, .cargoDoor, Path(roundedRect: CGRect(x: x - cargoDoorWidth / 2, y: yb + 0.10 * D,
                                                             width: cargoDoorWidth, height: min(D * 0.25, 1.75)), cornerRadius: 0.12))
        }
        func windowRow(y: Double, from: Double, to: Double, upper: Bool) {
            var wx = from
            while wx <= to {
                let blocked = doors.contains { $0.upper == upper && abs($0.x - wx) < $0.width / 2 + windowWidth * 0.9 }
                if !blocked {
                    add(.windows, .window, Path(roundedRect: CGRect(x: wx - windowWidth / 2, y: y - windowHeight / 2,
                                                                    width: windowWidth, height: windowHeight),
                                                cornerRadius: windowWidth * 0.42))
                }
                wx += windowPitch
            }
        }
        windowRow(y: windowY, from: firstWindow, to: L - lastWindowFromTail, upper: false)
        if let deck = upperDeck { windowRow(y: deck.windowY, from: deck.firstWindow, to: deck.lastWindow, upper: true) }

        // Fin ----------------------------------------------------------------------------------
        // A T-tail's fin stops under the tailplane, which takes the top of the drawing.
        let tpThick = 0.09 * D
        let finTop = tTail ? height - tailplaneRise - tpThick * 0.35 : height
        let finRootLE = L - finRootLEFromTail
        let finRootTE = finRootLE + finRootChord
        let finTipLE = finRootLE + finSweep
        let finTipTE = finTipLE + finTipChord
        let finBaseY = topY(finRootLE)
        let finH = finTop - finBaseY
        let root = p(finRootLE, finBaseY), tip = p(finTipLE, finTop)
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
            finPath.addLine(to: lerp(root, tip, self.fin == .clipped || tTail ? 0.985 : 0.96))
        }
        let teAt = { (f: Double) in lerp(p(finRootTE, topY(finRootTE)), p(finTipTE, finTop), f) }
        switch self.fin {
        case _ where tTail:
            // Square tip under the tailplane.
            finPath.addQuadCurve(to: p(finTipLE + finTipChord * 0.04, finTop), control: tip)
            finPath.addLine(to: p(finTipTE, finTop))
        case .curvedTip:
            // A350: the tip rounds down into the trailing edge.
            finPath.addQuadCurve(to: p(finTipLE + finTipChord * 0.10, finTop), control: tip)
            finPath.addLine(to: p(finTipLE + finTipChord * 0.45, finTop))
            finPath.addCurve(to: teAt(0.80), control1: p(finTipTE + finTipChord * 0.05, finTop),
                         control2: lerp(teAt(0.80), teAt(1), 0.55))
        case .clipped:
            finPath.addQuadCurve(to: p(finTipLE + finTipChord * 0.04, finTop), control: tip)
            finPath.addLine(to: p(finTipTE, finTop))
        default:
            finPath.addQuadCurve(to: p(finTipLE + finTipChord * 0.12, finTop), control: tip)
            finPath.addLine(to: p(finTipTE - finTipChord * 0.06, finTop))
            finPath.addQuadCurve(to: teAt(0.985), control: p(finTipTE, finTop))
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
        rudder.addLine(to: lerp(p(finTipTE, finTop), tip, 0.32))
        add(.tail, .panelLine, rudder)

        if tTail {
            // Tailplane on the fin tip: a slim swept strip seen almost edge on, the near tip a little higher,
            // with a bullet fairing where it meets the fin.
            let tpA = p(finTipLE - tailplaneChord * 0.06, finTop - tpThick * 0.15)
            let tpTip = tailplaneChord * 0.42
            let tpB = p(tpA.x + min(tailplaneRun, L - 0.2 - tpA.x - tpTip), height)
            let tpC = p(tpB.x + tpTip, height - tpThick * 0.55)
            let tpE = p(max(finTipTE + tailplaneChord * 0.08, tpA.x + tailplaneChord), finTop - tpThick * 0.75)
            var tailplane = Path()
            tailplane.move(to: tpA)
            tailplane.addCurve(to: tpB, control1: lerp(tpA, tpB, 0.35), control2: lerp(tpA, tpB, 0.75))
            tailplane.addQuadCurve(to: tpC, control: p(tpB.x + tpTip * 0.6, tpB.y + 0.004 * D))
            tailplane.addLine(to: tpE)
            tailplane.addCurve(to: tpA, control1: p(tpE.x - tailplaneChord * 0.45, tpE.y - tpThick * 0.25),
                               control2: p(tpA.x + tailplaneChord * 0.08, tpA.y - tpThick * 0.9))
            tailplane.closeSubpath()
            add(.tail, .tailplane, tailplane)
            var elevator = Path()
            elevator.move(to: lerp(tpE, tpA, 0.30))
            elevator.addLine(to: lerp(tpC, tpB, 0.30))
            add(.tail, .panelLine, elevator)
            var bullet = Path()
            let bx0 = finTipLE - tailplaneChord * 0.20, bx1 = tpE.x + tailplaneChord * 0.12, by = finTop - tpThick * 0.1
            bullet.move(to: p(bx0, by))
            bullet.addQuadCurve(to: p(bx1, by + tpThick * 0.05), control: p(bx0 + 0.1, by + tpThick * 0.75))
            bullet.addQuadCurve(to: p(bx0, by), control: p(bx0 + 0.1, by - tpThick * 0.65))
            bullet.closeSubpath()
            add(.tail, .tailplane, bullet)
        } else {
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
        }

        // Wing -----------------------------------------------------------------------------------
        // A high wing sits on the crown in its fairing; a low wing under the barrel.
        let zr = high ? yt + 0.05 * D : yb + 0.30 * D
        let tipLE = rootLE + wingSweep
        let zt = zr + wingRise
        let depthRoot = (high ? 0.20 : D > 5 ? 0.24 : 0.19) * D, depthTip = max(0.10, 0.035 * D)
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
            // Inboard: the lower surface running back into the belly fairing (or the crown fairing).
            w.addCurve(to: q(wa), control1: q(p(rootLE + cr * 0.55, zr - depthRoot * 1.02)),
                       control2: q(p(rootLE + cr * 0.06, zr - depthRoot * 0.55)))
            w.closeSubpath()
            return w
        }
        add(.wingFar, .wing, wingPath(dx: wingSweep * 0.03, dy: (high ? 0.03 : 0.12) * D))

        if high {
            // Main gear sponson low on the fuselage side.
            let s0 = bellyStart, s1 = bellyEnd, top = yb + 0.30 * D
            var sponson = Path()
            sponson.move(to: p(s0 - 0.2, yb + 0.02 * D))
            sponson.addCurve(to: p(s0 + (s1 - s0) * 0.30, top), control1: p(s0 + 0.1, yb + 0.22 * D), control2: p(s0 + (s1 - s0) * 0.12, top))
            sponson.addLine(to: p(s0 + (s1 - s0) * 0.72, top))
            sponson.addCurve(to: p(s1 + 0.2, yb), control1: p(s1 - (s1 - s0) * 0.08, top), control2: p(s1, yb + 0.12 * D))
            sponson.addCurve(to: p(s0, yb), control1: p(s1 - (s1 - s0) * 0.22, yb - bulge * 1.33),
                             control2: p(s0 + (s1 - s0) * 0.18, yb - bulge * 1.33))
            sponson.closeSubpath()
            add(.wing, .fairing, sponson)
        } else {
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
        }

        // A high wing goes on after the near nacelle that hangs from it (see the turboprop case below).
        if !high { add(.wing, .wing, wingPath(dx: 0, dy: 0)) }
        // Slat line just behind the leading edge, flap line ahead of the trailing edge.
        if !high {
            var slat = Path()
            slat.move(to: p(rootLE + 0.5, leZ(rootLE + 0.5) - 0.035 * D))
            slat.addLine(to: p(tipLE - 0.2, zt - 0.02 * D))
            add(.wing, .panelLine, slat)
        }
        var flap = Path()
        flap.move(to: p(rootTE.x - cr * 0.18, rootTE.y + 0.05 * D))
        flap.addLine(to: p(wk.x - cr * 0.12, wk.y + 0.04 * D))
        flap.addLine(to: p(wc.x - wingTipChord * 0.45, wc.y + 0.012 * D))
        if !high { add(.wing, .panelLine, flap) }

        // Flap track fairings: small pods hanging under the trailing edge, pointed aft.
        let pods: [Double] = high ? [] : family.isWidebody || family == .other && D > 5 ? [0.18, 0.40, 0.60, 0.78] : [0.22, 0.48, 0.74]
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
        /// A turbofan with its inlet at `x0` and its axis at `z`; `rear` hangs it on a stub from the aft
        /// fuselage instead of a pylon into the wing.
        func engine(x0: Double, z: Double, rear: Bool, layer: AircraftLayer) {
            let d = engineDiameter, l = engineLength
            let flat = engineStyle == .flatBottom, long = engineStyle == .longDuct
            let fanLen = l * (long ? 0.84 : d > 3.6 ? 0.66 : 0.62)
            let cowlEnd = x0 + fanLen
            let low = flat ? 0.42 : 0.49
            let nozzleR = (long ? 0.30 : 0.39) * d, nozzleLow = flat ? 0.33 * d : long ? 0.30 * d : 0.39 * d

            var pylon = Path()
            if rear {
                // Stub from the fuselage side, its lower surface just showing above the nacelle.
                pylon.move(to: p(x0 + l * 0.22, z + 0.40 * d))
                pylon.addLine(to: p(x0 + l * 0.36, z + 0.64 * d))
                pylon.addLine(to: p(x0 + l * 0.76, z + 0.60 * d))
                pylon.addLine(to: p(x0 + l * 0.84, z + 0.36 * d))
            } else {
                // Pylon up into the wing's lower surface.
                pylon.move(to: p(x0 + l * 0.14, z + 0.47 * d))
                pylon.addLine(to: p(x0 + l * 0.30, max(z + 0.5 * d, leZ(x0 + l * 0.30) - 0.03 * D)))
                pylon.addLine(to: p(x0 + l * 0.98, max(z + 0.38 * d, leZ(x0 + l * 0.98) - 0.10 * D)))
                pylon.addQuadCurve(to: p(x0 + l * 0.84, z + 0.17 * d), control: p(x0 + l * 0.95, z + 0.24 * d))
            }
            pylon.closeSubpath()
            add(layer, .pylon, pylon)

            // Core cowl and exhaust plug behind the fan cowl.
            let coreEnd = x0 + l * (long ? 0.93 : 0.86)
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
            n.addCurve(to: p(cowlEnd, z + nozzleR), control1: p(x0 + l * 0.24, z + 0.54 * d), control2: p(x0 + l * (long ? 0.60 : 0.48), z + 0.50 * d))
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
            n.addCurve(to: p(x0 + 0.02 * d, z - (low - 0.02) * d), control1: p(x0 + l * (long ? 0.60 : 0.48), z - (low + 0.01) * d),
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

        /// A turboprop under the high wing: nacelle running back past the trailing edge, chin intake,
        /// spinner and the propeller seen edge on (blades at their projected lengths).
        func turboprop(x0: Double, z: Double, layer: AircraftLayer) {
            let d = engineDiameter, l = engineLength, r = propellerDiameter / 2
            var n = Path()
            n.move(to: p(x0 + 0.10, z + 0.34 * d))
            n.addCurve(to: p(x0 + 1.1, z + 0.50 * d), control1: p(x0 + 0.35, z + 0.48 * d), control2: p(x0 + 0.7, z + 0.50 * d))
            n.addLine(to: p(x0 + l * 0.60, z + 0.50 * d))
            n.addCurve(to: p(x0 + l, z + 0.14 * d), control1: p(x0 + l * 0.82, z + 0.48 * d), control2: p(x0 + l * 0.96, z + 0.24 * d))
            n.addLine(to: p(x0 + l - 0.04, z + 0.02 * d))
            n.addCurve(to: p(x0 + l * 0.42, z - 0.50 * d), control1: p(x0 + l * 0.84, z - 0.24 * d), control2: p(x0 + l * 0.62, z - 0.50 * d))
            n.addLine(to: p(x0 + 0.9, z - 0.50 * d))
            n.addCurve(to: p(x0 + 0.10, z - 0.30 * d), control1: p(x0 + 0.45, z - 0.50 * d), control2: p(x0 + 0.15, z - 0.44 * d))
            n.closeSubpath()
            add(layer, .nacelle, n)
            // Chin intake under the spinner, and the exhaust stack behind the wing.
            var lip = Path()
            lip.move(to: p(x0 + 0.16, z - 0.14 * d))
            lip.addCurve(to: p(x0 + 0.16, z - 0.46 * d), control1: p(x0 + 0.06, z - 0.20 * d), control2: p(x0 + 0.06, z - 0.40 * d))
            lip.addCurve(to: p(x0 + 0.16, z - 0.14 * d), control1: p(x0 + 0.28, z - 0.40 * d), control2: p(x0 + 0.28, z - 0.20 * d))
            lip.closeSubpath()
            add(layer, .inlet, lip)
            add(layer, .exhaust, Path(roundedRect: CGRect(x: x0 + l * 0.64, y: z - 0.06 * d, width: l * 0.10, height: 0.26 * d), cornerRadius: 0.08 * d))
            // Spinner.
            var spinner = Path()
            spinner.move(to: p(x0 + 0.12, z + 0.30 * d))
            spinner.addCurve(to: p(x0 - 0.62, z), control1: p(x0 - 0.22, z + 0.30 * d), control2: p(x0 - 0.56, z + 0.12 * d))
            spinner.addCurve(to: p(x0 + 0.12, z - 0.30 * d), control1: p(x0 - 0.56, z - 0.12 * d), control2: p(x0 - 0.22, z - 0.30 * d))
            spinner.closeSubpath()
            // Blades: one up and one down at full length, two more between at half their length (six blades
            // seen edge on), each a slim twisted leaf.
            let xp = x0 - 0.02
            func blade(_ reach: Double, _ dir: Double, _ dx: Double) -> Path {
                let r0 = z + dir * 0.22 * d, r1 = z + dir * reach, w = 0.26
                var b = Path()
                b.move(to: p(xp + dx - 0.04, r0))
                b.addCurve(to: p(xp + dx + 0.01, r1), control1: p(xp + dx - w, r0 + dir * reach * 0.30),
                           control2: p(xp + dx - w * 0.45, r1 - dir * reach * 0.10))
                b.addCurve(to: p(xp + dx + 0.06, r0), control1: p(xp + dx + w * 0.35, r1 - dir * reach * 0.25),
                           control2: p(xp + dx + w * 0.40, r0 + dir * reach * 0.25))
                b.closeSubpath()
                return b
            }
            for (reach, dir, dx) in [(r * 0.5, 1.0, 0.10), (r * 0.5, -1.0, 0.10), (r, 1.0, 0.0), (r, -1.0, 0.0)] {
                add(layer, .propeller, blade(reach, dir, dx))
            }
            add(layer, .spinner, spinner)
        }

        let eX = rootLE + engineInletFromWing
        let eZ = engineClearance + engineDiameter / 2
        let farDX = wingSweep * 0.03, farDY = 0.10 * D
        switch engineMount {
        case .wing:
            // Far side behind the hull, outboard first; near side inboard first, the outboard engine (nearer
            // the eye) over it.
            if let out = outboardEngine {
                engine(x0: rootLE + out.inletFromWing + farDX, z: out.clearance + engineDiameter / 2 + farDY, rear: false, layer: .engineFar)
            }
            engine(x0: eX + farDX, z: eZ + farDY, rear: false, layer: .engineFar)
            engine(x0: eX, z: eZ, rear: false, layer: .engine)
            if let out = outboardEngine {
                engine(x0: rootLE + out.inletFromWing, z: out.clearance + engineDiameter / 2, rear: false, layer: .engine)
            }
        case .rear:
            let x0 = L - rearEngineInletFromTail, z = yb + rearEngineLine * D
            engine(x0: x0, z: z + 0.03 * D, rear: true, layer: .engineFar)
            engine(x0: x0, z: z, rear: true, layer: .engine)
        case .turboprop:
            // The nacelle hangs from the wing: its top tucks into the wing's lower surface, so the axis sits
            // just under the crown and the propeller turns ahead of the wing, not low on the cabin.
            let z = zr - depthRoot * 0.6 - engineDiameter * 0.36
            turboprop(x0: eX + 0.12, z: z + 0.05 * D, layer: .engineFar)
            turboprop(x0: eX, z: z, layer: .engine)
        }
        if high {
            // The near high wing over the nacelle's top, so the engine reads as hanging under it.
            add(.engine, .wing, wingPath(dx: 0, dy: 0))
            add(.engine, .panelLine, flap)
        }

        // Gear ----------------------------------------------------------------------------------
        let legTop = high ? yb + 0.22 * D : zr - depthRoot * 0.6
        func mainLeg(x mx: Double, axles: Int, layer: AircraftLayer, near: Bool) {
            let span = axleSpacing * Double(axles - 1)
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
            if axles > 1 {
                add(layer, .strut, Path(roundedRect: CGRect(x: mx - span / 2 - 0.1, y: mainTyre - 0.09, width: span + 0.2, height: 0.18),
                                        cornerRadius: 0.09))
            }
            for i in 0..<axles {
                let cx = mx - span / 2 + axleSpacing * Double(i)
                add(layer, .tyre, Path(ellipseIn: CGRect(x: cx - mainTyre, y: 0, width: mainTyre * 2, height: mainTyre * 2)))
                if near { add(layer, .hub, Path(ellipseIn: CGRect(x: cx - mainTyre * 0.42, y: mainTyre * 0.58, width: mainTyre * 0.84, height: mainTyre * 0.84))) }
            }
        }
        func gear(dx: Double, layer: AircraftLayer, near: Bool) {
            let nx = noseGearX + dx
            add(layer, .strut, Path(roundedRect: CGRect(x: nx - 0.08, y: noseTyre, width: 0.16, height: yb - noseTyre + 0.05),
                                    cornerRadius: 0.05))
            add(layer, .tyre, Path(ellipseIn: CGRect(x: nx - noseTyre, y: 0, width: noseTyre * 2, height: noseTyre * 2)))
            if near { add(layer, .hub, Path(ellipseIn: CGRect(x: nx - noseTyre * 0.42, y: noseTyre * 0.58, width: noseTyre * 0.84, height: noseTyre * 0.84))) }
            // Wing gear ahead of the body gear on the four-engined widebodies.
            if let wg = wingGear { mainLeg(x: mainGearX + wg.dx + dx, axles: wg.axles, layer: layer, near: near) }
            mainLeg(x: mainGearX + dx, axles: mainAxles, layer: layer, near: near)
        }
        gear(dx: 0.3, layer: .gearFar, near: false)
        gear(dx: 0, layer: .gear, near: true)

        // Slots ---------------------------------------------------------------------------------
        let midY = finBaseY + finH * 0.52
        let midLE = finRootLE + finSweep * 0.52, midTE = finRootTE + (finTipTE - finRootTE) * 0.52
        let chord = midTE - midLE
        let finBox = CGRect(x: midLE + chord * 0.16, y: midY - finH * 0.27, width: chord * 0.62, height: finH * 0.54)
        let band = (windowY - windowHeight * 0.9)...(windowY + windowHeight * 0.9)
        // A turboprop's title goes behind the nacelle, clear of the propeller.
        let titleX = engineMount == .turboprop ? eX + engineLength + 0.4 : firstWindow + windowPitch * 2
        let anchor = CGPoint(x: titleX, y: windowY + windowHeight * 0.75)
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
        case .canted:
            // A330, 747-400, E-Jets, CRJ: a straight-edged winglet canted up and swept, its trailing edge
            // dropping back into the tip.
            w.move(to: p(tipLE + c * 0.02, tipZ + thick * 0.5))
            w.addQuadCurve(to: p(tipLE + c * 0.30, tipZ + h * 0.30), control: p(tipLE + c * 0.14, tipZ + thick * 0.6))
            w.addLine(to: p(tipLE + c * 0.86, tipZ + h))
            w.addLine(to: p(tipLE + c * 1.22, tipZ + h))
            w.addCurve(to: p(tipTE, tipZ - thick * 0.5), control1: p(tipLE + c * 1.14, tipZ + h * 0.45), control2: p(tipTE + c * 0.06, tipZ + h * 0.10))
            w.closeSubpath()
        case .fence:
            // A380 wingtip fence: a swept plate standing above and below the tip.
            w.move(to: p(tipLE + c * 0.10, tipZ + thick * 0.3))
            w.addLine(to: p(tipLE + c * 0.80, tipZ + h))
            w.addLine(to: p(tipLE + c * 1.05, tipZ + h))
            w.addLine(to: p(tipTE + c * 0.08, tipZ))
            w.addLine(to: p(tipLE + c * 0.86, tipZ - h * 0.55))
            w.addLine(to: p(tipLE + c * 0.64, tipZ - h * 0.55))
            w.closeSubpath()
        }
        return w
    }
}
