import CoreGraphics
import SwiftUI

/// Draw order of a side view, back to front. The far wing, engine and gear sit behind the fuselage;
/// the near ones in front of it.
public enum AircraftLayer: Int, CaseIterable, Sendable {
    case gearFar, wingFar, engineFar, fuselage, windows, doors, wing, engine, tail, gear
}

/// What a path is, so a livery can paint each part on its own: the hull takes the fuselage top, belly
/// and cheatline (clipped to it), the fin the tail paint, the nacelles the engine colour.
public enum AircraftPart: String, CaseIterable, Sendable {
    case hull, fin, tailplane, wing, flapFairing, winglet, pylon, nacelle, inlet, exhaust
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
    /// default, else the generic body. `nil` gives the generic narrowbody.
    public static func geometry(type: AircraftType?) -> AircraftGeometry {
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

// MARK: - Spec

/// The few numbers that make an airliner in profile. Lengths in metres; "from tail" distances are
/// measured forward from the aft end, so a stretch only moves the barrel.
struct AirlinerSpec {
    enum Nose { case airbus, b737, b777, b787, a350 }
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

    // Fin: root leading edge and chord, tip chord, sweep run (tip LE x minus root LE x).
    var finRootLEFromTail: Double
    var finRootChord: Double
    var finTipChord: Double
    var finSweep: Double
    var finFillet: Double

    // Horizontal tail.
    var tailplaneLEFromTail: Double
    var tailplaneChord: Double
    var tailplaneRun: Double
    var tailplaneRise: Double

    // Wing (projection of the near wing).
    var wingRootLE: Double
    var wingRootChord: Double
    var wingTipChord: Double
    var wingSweep: Double
    var wingRise: Double
    var winglet: Winglet
    var wingletHeight: Double

    // Engine under the wing.
    var engineDiameter: Double
    var engineLength: Double
    var engineClearance: Double
    /// Inlet x relative to the wing root leading edge.
    var engineInletFromWing: Double
    /// Fraction of the wing's projected run where the pylon meets it.
    var engineSpan: Double
    var engineStyle: EngineStyle

    // Gear.
    var noseGearX: Double
    var mainGearX: Double
    var noseTyre: Double
    var mainTyre: Double
    var mainAxles: Int
    var axleSpacing: Double

    // Cabin.
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

extension AirlinerSpec {
    func build() -> AircraftGeometry {
        var shapes: [AircraftShape] = []
        func add(_ layer: AircraftLayer, _ part: AircraftPart, _ path: Path) {
            shapes.append(AircraftShape(layer: layer, part: part, path: path))
        }
        let L = length, D = diameter, yb = bottom, yt = bottom + diameter
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

        // Hull ----------------------------------------------------------------------------------
        // Nose tip height and the upper and lower curve controls (fractions of the diameter and nose
        // length), then the cockpit window sill and the panes along the nose (fractions of its length).
        let noseTip: Double, upperK: (Double, Double), lowerK: Double, sill: Double, panes: [(Double, Double)]
        switch nose {
        case .airbus: noseTip = 0.34; upperK = (0.25, 0.50); lowerK = 0.30; sill = 0.675
            panes = [(0.40, 0.53), (0.55, 0.67), (0.69, 0.79)]
        case .b737: noseTip = 0.33; upperK = (0.22, 0.56); lowerK = 0.26; sill = 0.665
            panes = [(0.44, 0.55), (0.57, 0.67), (0.69, 0.77)]
        case .b777: noseTip = 0.33; upperK = (0.24, 0.54); lowerK = 0.30; sill = 0.705
            panes = [(0.47, 0.58), (0.60, 0.70), (0.72, 0.80)]
        case .b787: noseTip = 0.38; upperK = (0.22, 0.64); lowerK = 0.32; sill = 0.715
            panes = [(0.50, 0.62), (0.64, 0.76)]
        case .a350: noseTip = 0.35; upperK = (0.26, 0.54); lowerK = 0.30; sill = 0.69
            panes = [(0.44, 0.56), (0.58, 0.69), (0.71, 0.80)]
        }
        let tipY = yb + noseTip * D
        let upperNose = Cubic(p0: p(0, tipY), p1: p(0, tipY + upperK.0 * D),
                              p2: p(noseLength * upperK.1, yt), p3: p(noseLength, yt))
        let tailStart = L - tailLength
        let tipTop = yb + 0.70 * D, tipBottom = yb + 0.56 * D
        let upperTail = Cubic(p0: p(L - tailLength * 0.72, yt), p1: p(L - tailLength * 0.34, yt),
                              p2: p(L - tailLength * 0.06, tipTop + 0.10 * D), p3: p(L, tipTop))
        func topY(_ x: Double) -> Double {
            if x <= noseLength { return upperNose.y(atX: x) }
            if x <= upperTail.p0.x { return yt }
            return upperTail.y(atX: min(x, L))
        }
        let fairStart = wingRootLE - wingRootChord * 0.22
        let fairEnd = wingRootLE + wingRootChord * 1.25
        let bulge = D * 0.09

        var hull = Path()
        hull.move(to: p(0, tipY))
        hull.addCurve(to: upperNose.p3, control1: upperNose.p1, control2: upperNose.p2)
        hull.addLine(to: upperTail.p0)
        hull.addCurve(to: upperTail.p3, control1: upperTail.p1, control2: upperTail.p2)
        hull.addLine(to: p(L, tipBottom))
        hull.addCurve(to: p(tailStart, yb), control1: p(L - tailLength * 0.42, yb + 0.30 * D),
                      control2: p(L - tailLength * 0.78, yb))
        hull.addLine(to: p(fairEnd, yb))
        hull.addCurve(to: p(fairStart, yb), control1: p(fairEnd - (fairEnd - fairStart) * 0.25, yb - bulge * 1.33),
                      control2: p(fairStart + (fairEnd - fairStart) * 0.2, yb - bulge * 1.33))
        hull.addLine(to: p(noseLength * 0.9, yb))
        hull.addCurve(to: p(0, tipY), control1: p(noseLength * 0.38, yb), control2: p(0, tipY - lowerK * D))
        hull.closeSubpath()
        add(.fuselage, .hull, hull)

        // APU exhaust at the tail cone.
        let apuH = (tipTop - tipBottom) * 0.55
        add(.fuselage, .apu, Path(ellipseIn: CGRect(x: L - 0.08, y: (tipTop + tipBottom - apuH) / 2, width: 0.08, height: apuH)))

        // Cockpit ---------------------------------------------------------------------------------
        let cockpitBottom = yb + sill * D
        let inset = 0.07 * D
        func pane(_ x0: Double, _ x1: Double, front: Bool, aft: Bool) -> Path {
            var path = Path()
            let top0 = topY(x0) - inset
            path.move(to: p(front ? x0 + (top0 - cockpitBottom) * 0.6 : x0, cockpitBottom))
            path.addLine(to: p(x0, top0))
            for i in 1...6 {
                let x = x0 + (x1 - x0) * Double(i) / 6
                path.addLine(to: p(x, topY(x) - inset))
            }
            path.addLine(to: p(aft ? x1 - (topY(x1) - inset - cockpitBottom) * 0.45 : x1, cockpitBottom))
            path.closeSubpath()
            return path
        }
        let nl = noseLength
        if nose == .a350 {
            // The "panda mask": a black surround from the windscreen back past the side windows, its aft
            // end swept down to a rounded point.
            let m0 = nl * 0.38, m1 = nl * 0.86, mb = cockpitBottom - 0.035 * D
            var mask = Path()
            mask.move(to: p(m0 + 0.05 * D, mb))
            mask.addLine(to: p(m0 - 0.02 * D, topY(m0) - inset * 0.55))
            for i in 1...10 {
                let x = m0 + (m1 - m0) * Double(i) / 10
                mask.addLine(to: p(x, topY(x) - inset * 0.55))
            }
            mask.addCurve(to: p(m1 + 0.02 * D, mb - 0.01 * D), control1: p(m1 + 0.10 * D, topY(m1) - inset * 0.7),
                          control2: p(m1 + 0.09 * D, mb + 0.02 * D))
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
                let top = windowY + windowHeight * 0.5 + 0.30
                add(.doors, .door, Path(roundedRect: CGRect(x: door.x - door.width / 2, y: top - door.height,
                                                            width: door.width, height: door.height), cornerRadius: 0.16))
            }
        }
        let cargoH = D * 0.26
        for x in cargoDoors {
            let bottomAt = yb + 0.10 * D
            add(.doors, .cargoDoor, Path(roundedRect: CGRect(x: x - cargoDoorWidth / 2, y: bottomAt,
                                                             width: cargoDoorWidth, height: cargoH), cornerRadius: 0.12))
        }
        var x = firstWindow
        while x <= L - lastWindowFromTail {
            let blocked = doors.contains { abs($0.x - x) < $0.width / 2 + windowWidth * 0.9 }
            if !blocked {
                add(.windows, .window, Path(roundedRect: CGRect(x: x - windowWidth / 2, y: windowY - windowHeight / 2,
                                                                width: windowWidth, height: windowHeight),
                                            cornerRadius: windowWidth * 0.46))
            }
            x += windowPitch
        }

        // Fin and tailplane ----------------------------------------------------------------------
        let finRootLE = L - finRootLEFromTail
        let finRootTE = finRootLE + finRootChord
        let finTipLE = finRootLE + finSweep
        let finTipTE = finTipLE + finTipChord
        let finBaseY = topY(finRootLE)
        let finH = height - finBaseY
        var fin = Path()
        let filletStart = finRootLE - finFillet
        fin.move(to: p(filletStart, topY(filletStart)))
        let lePoint = { (f: Double) in self.lerp(p(finRootLE, finBaseY), p(finTipLE, height), f) }
        fin.addCurve(to: lePoint(0.24), control1: p(finRootLE - finFillet * 0.45, topY(finRootLE - finFillet * 0.45) + 0.04),
                     control2: lerp(p(finRootLE, finBaseY), p(finTipLE, height), 0.08))
        fin.addLine(to: lePoint(0.97))
        fin.addQuadCurve(to: p(finTipLE + finTipChord * 0.12, height), control: p(finTipLE, height))
        fin.addLine(to: p(finTipTE, height))
        fin.addLine(to: p(finRootTE, topY(finRootTE)))
        let steps = 16
        for i in 1...steps {
            let xx = finRootTE - (finRootTE - filletStart) * Double(i) / Double(steps)
            fin.addLine(to: p(xx, topY(xx)))
        }
        fin.closeSubpath()
        add(.tail, .fin, fin)

        let tpLE = L - tailplaneLEFromTail
        let tpY = yb + 0.58 * D
        var tailplane = Path()
        tailplane.move(to: p(tpLE, tpY))
        tailplane.addCurve(to: p(tpLE + tailplaneRun, tpY + tailplaneRise + 0.06),
                           control1: p(tpLE + tailplaneRun * 0.3, tpY + 0.12), control2: p(tpLE + tailplaneRun * 0.7, tpY + tailplaneRise))
        tailplane.addLine(to: p(tpLE + tailplaneRun + tailplaneChord * 0.35, tpY + tailplaneRise))
        tailplane.addLine(to: p(tpLE + tailplaneChord, tpY - 0.10))
        tailplane.addQuadCurve(to: p(tpLE, tpY), control: p(tpLE + tailplaneChord * 0.1, tpY - 0.14))
        tailplane.closeSubpath()
        add(.tail, .tailplane, tailplane)

        // Wing ----------------------------------------------------------------------------------
        let wingZ = yb + 0.08 * D
        let thick = wingRootChord * 0.075
        let tipLE = wingRootLE + wingSweep
        let tipZ = wingZ + wingRise
        let tipTE = tipLE + wingTipChord
        func wingPath(dx: Double, dy: Double) -> Path {
            var w = Path()
            w.move(to: p(wingRootLE + dx, wingZ + thick * 0.55 + dy))
            w.addCurve(to: p(tipLE + dx, tipZ + thick * 0.25 + dy),
                       control1: p(wingRootLE + wingSweep * 0.3 + dx, wingZ + thick * 0.6 + wingRise * 0.28 + dy),
                       control2: p(tipLE - wingSweep * 0.2 + dx, tipZ + thick * 0.25 + dy))
            w.addLine(to: p(tipTE + dx, tipZ + dy))
            w.addCurve(to: p(wingRootLE + wingRootChord + dx, wingZ - thick * 0.15 + dy),
                       control1: p(tipTE - wingSweep * 0.35 + dx, tipZ - wingRise * 0.35 + dy),
                       control2: p(wingRootLE + wingRootChord + wingSweep * 0.15 + dx, wingZ + dy))
            w.addCurve(to: p(wingRootLE + dx, wingZ + thick * 0.55 + dy),
                       control1: p(wingRootLE + wingRootChord * 0.55 + dx, wingZ - thick * 0.9 + dy),
                       control2: p(wingRootLE - wingRootChord * 0.04 + dx, wingZ - thick * 0.2 + dy))
            w.closeSubpath()
            return w
        }
        let farOffset = (dx: wingSweep * 0.035, dy: wingRise * 0.09)
        add(.wingFar, .wing, wingPath(dx: farOffset.dx, dy: farOffset.dy))
        add(.wing, .wing, wingPath(dx: 0, dy: 0))
        for f in [0.30, 0.52, 0.74] {
            let le = wingRootLE + wingSweep * f
            let chord = wingRootChord + (wingTipChord - wingRootChord) * f
            let z = wingZ + wingRise * f
            let c0 = le + chord * 0.55, len = chord * 0.62, h = max(0.18, D * 0.05)
            let zz = z - thick * 0.1
            var canoe = Path()
            canoe.move(to: p(c0, zz))
            canoe.addCurve(to: p(c0 + len, zz - h * 0.15), control1: p(c0 + len * 0.25, zz - h * 1.3), control2: p(c0 + len * 0.85, zz - h * 0.9))
            canoe.addLine(to: p(c0 + len * 0.5, zz))
            canoe.closeSubpath()
            add(.wing, .flapFairing, canoe)
        }
        if let tip = wingletPath(tipLE: tipLE, tipTE: tipTE, tipZ: tipZ, thick: thick) {
            add(.wing, .winglet, tip)
        }

        // Engines ---------------------------------------------------------------------------------
        let eX = wingRootLE + engineInletFromWing
        let eZ = engineClearance + engineDiameter / 2
        let wingAtEngine = (x: wingRootLE + wingSweep * engineSpan, z: wingZ + wingRise * engineSpan)
        func engine(dx: Double, dy: Double, layer: AircraftLayer) {
            let d = engineDiameter, l = engineLength, x0 = eX + dx, z = eZ + dy
            let flat = engineStyle == .flatBottom
            let bottomR = flat ? 0.40 * d : 0.5 * d
            let cowlEnd = x0 + l * 0.66
            var n = Path()
            n.move(to: p(x0, z + 0.47 * d))
            n.addCurve(to: p(cowlEnd, z + 0.40 * d), control1: p(x0 + l * 0.22, z + 0.53 * d), control2: p(x0 + l * 0.48, z + 0.50 * d))
            if engineStyle == .chevron {
                // Serrated fan nozzle: chevrons from the cowl's top edge down to its bottom edge.
                let teeth = 7
                for i in 0..<teeth {
                    let b = z + 0.40 * d - 0.80 * d * (Double(i) + 0.5) / Double(teeth)
                    n.addLine(to: p(cowlEnd + l * 0.028, b))
                    n.addLine(to: p(cowlEnd, z + 0.40 * d - 0.80 * d * Double(i + 1) / Double(teeth)))
                }
            } else {
                n.addLine(to: p(cowlEnd, z - (flat ? 0.34 : 0.40) * d))
            }
            n.addCurve(to: p(x0, z - (bottomR - 0.03 * d)), control1: p(x0 + l * 0.48, z - bottomR - 0.02 * d),
                       control2: p(x0 + l * 0.2, z - bottomR - 0.02 * d))
            n.addCurve(to: p(x0, z + 0.47 * d), control1: p(x0 - 0.07 * d, z - 0.2 * d), control2: p(x0 - 0.07 * d, z + 0.3 * d))
            n.closeSubpath()

            // Core cowl, nozzle and plug behind the fan cowl.
            var core = Path()
            let coreEnd = x0 + l
            core.move(to: p(cowlEnd - 0.05, z + 0.30 * d))
            core.addCurve(to: p(coreEnd - l * 0.06, z + 0.15 * d), control1: p(cowlEnd + l * 0.12, z + 0.28 * d), control2: p(coreEnd - l * 0.15, z + 0.18 * d))
            core.addQuadCurve(to: p(coreEnd, z), control: p(coreEnd - l * 0.01, z + 0.10 * d))
            core.addQuadCurve(to: p(coreEnd - l * 0.06, z - 0.13 * d), control: p(coreEnd - l * 0.01, z - 0.09 * d))
            core.addCurve(to: p(cowlEnd - 0.05, z - (flat ? 0.26 : 0.30) * d), control1: p(coreEnd - l * 0.15, z - 0.16 * d),
                          control2: p(cowlEnd + l * 0.12, z - 0.26 * d))
            core.closeSubpath()

            // Pylon up into the wing.
            var pylon = Path()
            pylon.move(to: p(x0 + l * 0.18, z + 0.46 * d))
            pylon.addLine(to: p(x0 + l * 0.30, wingAtEngine.z + dy + 0.15))
            pylon.addLine(to: p(max(wingAtEngine.x + wingRootChord * 0.45, coreEnd + 0.2) + dx, wingAtEngine.z + dy - 0.05))
            pylon.addQuadCurve(to: p(coreEnd - l * 0.02, z + 0.20 * d), control: p(coreEnd + l * 0.05, z + 0.35 * d))
            pylon.closeSubpath()

            // Inlet lip: a thin bright crescent at the front.
            var lip = Path()
            lip.move(to: p(x0, z + 0.47 * d))
            lip.addCurve(to: p(x0, z - (bottomR - 0.03 * d)), control1: p(x0 - 0.07 * d, z + 0.3 * d), control2: p(x0 - 0.07 * d, z - 0.2 * d))
            lip.addCurve(to: p(x0, z + 0.47 * d), control1: p(x0 + 0.02 * d, z - 0.2 * d), control2: p(x0 + 0.02 * d, z + 0.3 * d))
            lip.closeSubpath()

            add(layer, .pylon, pylon)
            add(layer, .exhaust, core)
            add(layer, .nacelle, n)
            add(layer, .inlet, lip)
        }
        engine(dx: wingSweep * 0.035, dy: wingRise * 0.09, layer: .engineFar)
        engine(dx: 0, dy: 0, layer: .engine)

        // Gear ----------------------------------------------------------------------------------
        func gear(dx: Double, layer: AircraftLayer, near: Bool) {
            // Nose gear.
            let nx = noseGearX + dx
            add(layer, .strut, Path(roundedRect: CGRect(x: nx - 0.09, y: noseTyre, width: 0.18, height: yb - noseTyre + 0.05),
                                    cornerRadius: 0.05))
            add(layer, .tyre, Path(ellipseIn: CGRect(x: nx - noseTyre, y: 0, width: noseTyre * 2, height: noseTyre * 2)))
            if near { add(layer, .hub, Path(ellipseIn: CGRect(x: nx - noseTyre * 0.45, y: noseTyre * 0.55, width: noseTyre * 0.9, height: noseTyre * 0.9))) }
            // Main gear: leg from the wing root to the bogie.
            let mx = mainGearX + dx
            let span = axleSpacing * Double(mainAxles - 1)
            add(layer, .strut, Path(roundedRect: CGRect(x: mx - 0.14, y: mainTyre, width: 0.28, height: wingZ - mainTyre),
                                    cornerRadius: 0.07))
            if mainAxles > 1 {
                add(layer, .strut, Path(roundedRect: CGRect(x: mx - span / 2, y: mainTyre - 0.09, width: span, height: 0.18),
                                        cornerRadius: 0.09))
            }
            for i in 0..<mainAxles {
                let cx = mx - span / 2 + axleSpacing * Double(i)
                add(layer, .tyre, Path(ellipseIn: CGRect(x: cx - mainTyre, y: 0, width: mainTyre * 2, height: mainTyre * 2)))
                if near { add(layer, .hub, Path(ellipseIn: CGRect(x: cx - mainTyre * 0.45, y: mainTyre * 0.55, width: mainTyre * 0.9, height: mainTyre * 0.9))) }
            }
        }
        gear(dx: 0.35, layer: .gearFar, near: false)
        gear(dx: 0, layer: .gear, near: true)

        // Slots ---------------------------------------------------------------------------------
        let midY = finBaseY + finH * 0.52
        let midLE = finRootLE + finSweep * 0.52, midTE = finRootTE + (finTipTE - finRootTE) * 0.52
        let chord = midTE - midLE
        let finBox = CGRect(x: midLE + chord * 0.18, y: midY - finH * 0.28, width: chord * 0.62, height: finH * 0.56)
        let band = (windowY - windowHeight * 0.9)...(windowY + windowHeight * 0.9)
        let anchor = CGPoint(x: firstWindow + windowPitch * 2, y: windowY + windowHeight * 0.75)
        return AircraftGeometry(family: family, lengthM: length, heightM: height, shapes: shapes, finBox: finBox,
                                cheatlineBand: band, titleAnchor: anchor, fuselageBottomM: yb, fuselageTopM: yt)
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// The wing tip device in profile, rising from the tip chord.
    private func wingletPath(tipLE: Double, tipTE: Double, tipZ: Double, thick: Double) -> Path? {
        let c = tipTE - tipLE, h = wingletHeight
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
        var w = Path()
        switch winglet {
        case .none:
            return nil
        case .sharklet:
            // Airbus sharklet: a smooth blend from the tip into a tall swept fin.
            w.move(to: p(tipLE - c * 0.1, tipZ + thick * 0.2))
            w.addCurve(to: p(tipLE + c * 0.9, tipZ + h), control1: p(tipLE + c * 0.35, tipZ + thick * 0.4), control2: p(tipLE + c * 0.62, tipZ + h * 0.45))
            w.addLine(to: p(tipLE + c * 1.22, tipZ + h))
            w.addCurve(to: p(tipTE, tipZ), control1: p(tipLE + c * 1.1, tipZ + h * 0.5), control2: p(tipTE + c * 0.05, tipZ + h * 0.15))
            w.closeSubpath()
        case .blended:
            // 737NG blended winglet: a long sweep with a large root radius.
            w.move(to: p(tipLE - c * 0.05, tipZ + thick * 0.2))
            w.addCurve(to: p(tipLE + c * 1.15, tipZ + h), control1: p(tipLE + c * 0.55, tipZ + thick * 0.2), control2: p(tipLE + c * 0.85, tipZ + h * 0.55))
            w.addLine(to: p(tipLE + c * 1.45, tipZ + h))
            w.addCurve(to: p(tipTE, tipZ), control1: p(tipLE + c * 1.3, tipZ + h * 0.45), control2: p(tipTE + c * 0.1, tipZ + h * 0.08))
            w.closeSubpath()
        case .splitScimitar:
            // 737 MAX: the upper scimitar plus a ventral blade pointing down and aft.
            w.move(to: p(tipLE - c * 0.05, tipZ + thick * 0.2))
            w.addCurve(to: p(tipLE + c * 1.1, tipZ + h), control1: p(tipLE + c * 0.5, tipZ + thick * 0.2), control2: p(tipLE + c * 0.8, tipZ + h * 0.55))
            w.addLine(to: p(tipLE + c * 1.38, tipZ + h * 1.02))
            w.addCurve(to: p(tipTE, tipZ + thick * 0.1), control1: p(tipLE + c * 1.25, tipZ + h * 0.45), control2: p(tipTE + c * 0.1, tipZ + h * 0.08))
            w.addLine(to: p(tipLE + c * 1.55, tipZ - h * 0.48))
            w.addLine(to: p(tipLE + c * 1.30, tipZ - h * 0.47))
            w.addCurve(to: p(tipLE + c * 0.15, tipZ), control1: p(tipLE + c * 0.8, tipZ - h * 0.22), control2: p(tipLE + c * 0.4, tipZ - 0.02))
            w.closeSubpath()
        case .raked:
            // Raked tip: the tip runs on aft to a point instead of rising.
            w.move(to: p(tipLE - c * 0.2, tipZ + thick * 0.25))
            w.addCurve(to: p(tipTE + c * 1.4, tipZ + h), control1: p(tipLE + c * 0.9, tipZ + thick * 0.3), control2: p(tipTE + c * 0.9, tipZ + h * 0.7))
            w.addCurve(to: p(tipTE - c * 0.1, tipZ), control1: p(tipTE + c * 1.0, tipZ + h * 0.3), control2: p(tipTE + c * 0.4, tipZ))
            w.closeSubpath()
        case .curled:
            // A350: the tip curls up and aft in one sweep.
            w.move(to: p(tipLE - c * 0.15, tipZ + thick * 0.2))
            w.addCurve(to: p(tipLE + c * 1.55, tipZ + h), control1: p(tipLE + c * 0.7, tipZ + thick * 0.2), control2: p(tipLE + c * 1.3, tipZ + h * 0.4))
            w.addQuadCurve(to: p(tipLE + c * 1.78, tipZ + h * 0.96), control: p(tipLE + c * 1.7, tipZ + h * 1.02))
            w.addCurve(to: p(tipTE, tipZ), control1: p(tipLE + c * 1.6, tipZ + h * 0.35), control2: p(tipTE + c * 0.25, tipZ + h * 0.05))
            w.closeSubpath()
        }
        return w
    }
}
