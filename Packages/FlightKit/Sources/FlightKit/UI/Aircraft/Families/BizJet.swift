import Foundation

/// Business jets in three sizes, drawn like the CRJ (a slim barrel, engines on the aft fuselage, a T-tail)
/// with fewer, larger oval windows: the long-range jets (Gulfstream G650, Global, Falcon 7X), the
/// super-midsize jets (Challenger 350, Falcon 2000, Citation Latitude) and the light jets (Citation CJ,
/// Phenom, PC-24). Proportions from the makers' published dimensions, rounded.
enum BizJet {
    private struct Variant {
        var length: Double, height: Double, diameter: Double, bottom: Double
        var noseLength: Double, tailLength: Double
        var rootLE: Double, rootChord: Double, tipChord: Double, sweep: Double
        var engineDiameter: Double, engineLength: Double
        var door: Double, windowPitch: Double, windowWidth: Double, windowHeight: Double
        var firstWindow: Double, lastWindowFromTail: Double
        /// The fin and tailplane, scaled from the CRJ's.
        var tail: Double
    }

    static let large: Set<String> = ["GLF4", "GLF5", "GLF6", "GA5C", "GA6C", "GA7C", "GA8C", "GLEX", "GL5T", "GL7T",
                                     "FA7X", "FA8X", "FA6X", "F900", "CL60", "E35L"]
    static let midsize: Set<String> = ["G280", "CL30", "CL35", "F2TH", "FA50", "C750", "C700", "C68A", "C680",
                                       "E545", "E550", "H25B"]

    private static func variant(_ icao: String?) -> Variant {
        if icao == nil || large.contains(icao ?? "") {
            // Gulfstream G650: 30.4 m long, 7.8 m high, 2.6 m barrel.
            return Variant(length: 30.4, height: 7.8, diameter: 2.6, bottom: 0.95, noseLength: 4.4, tailLength: 8.6,
                           rootLE: 12.6, rootChord: 5.4, tipChord: 1.1, sweep: 6.2, engineDiameter: 1.6,
                           engineLength: 4.4, door: 2.2, windowPitch: 1.05, windowWidth: 0.62, windowHeight: 0.46,
                           firstWindow: 4.6, lastWindowFromTail: 9.4, tail: 1.0)
        }
        if let icao, midsize.contains(icao) {
            // Challenger 350: 20.9 m long, 6.1 m high, 2.2 m barrel.
            return Variant(length: 20.9, height: 6.1, diameter: 2.2, bottom: 0.8, noseLength: 3.4, tailLength: 6.4,
                           rootLE: 8.6, rootChord: 3.8, tipChord: 1.0, sweep: 3.6, engineDiameter: 1.25,
                           engineLength: 3.3, door: 1.8, windowPitch: 0.86, windowWidth: 0.48, windowHeight: 0.38,
                           firstWindow: 3.6, lastWindowFromTail: 7.0, tail: 0.78)
        }
        // Citation CJ3 / Phenom 300: 15.6 m long, 4.6 m high, 1.7 m barrel.
        return Variant(length: 15.6, height: 4.6, diameter: 1.7, bottom: 0.55, noseLength: 2.8, tailLength: 5.0,
                       rootLE: 6.4, rootChord: 2.8, tipChord: 0.9, sweep: 1.4, engineDiameter: 0.95,
                       engineLength: 2.5, door: 1.5, windowPitch: 0.72, windowWidth: 0.38, windowHeight: 0.30,
                       firstWindow: 3.0, lastWindowFromTail: 5.4, tail: 0.6)
    }

    static func geometry(_ icao: String?) -> AircraftGeometry {
        let v = variant(icao)
        let k = v.tail
        var spec = AirlinerSpec(
            family: .bizjet, length: v.length, height: v.height, diameter: v.diameter, bottom: v.bottom,
            nose: .crj, noseLength: v.noseLength, tailLength: v.tailLength,
            fin: .swept, finRootLEFromTail: 6.9 * k, finRootChord: 4.8 * k, finTipChord: 2.6 * k,
            finSweep: 3.8 * k, finFillet: 1.6 * k,
            tailplaneLEFromTail: 0, tailplaneChord: 2.4 * k, tailplaneRun: 2.4 * k, tailplaneRise: 0.30 * k,
            wingRootLE: v.rootLE, wingRootChord: v.rootChord, wingTipChord: v.tipChord, wingSweep: v.sweep,
            wingRise: 0.7 * k, winglet: .canted, wingletHeight: 1.0 * k,
            engineDiameter: v.engineDiameter, engineLength: v.engineLength, engineClearance: 0,
            engineInletFromWing: 0, engineStyle: .plain,
            noseGearX: v.noseLength * 0.5, mainGearX: v.rootLE + v.rootChord * 0.6, noseTyre: 0.22 * k + 0.08,
            mainTyre: 0.34 * k + 0.1, mainAxles: 1, axleSpacing: 0,
            doors: [.init(x: v.door, width: 0.86 * max(k, 0.8), height: 1.6 * max(k, 0.8))], cargoDoors: [],
            cargoDoorWidth: 0.8,
            windowPitch: v.windowPitch, windowWidth: v.windowWidth, windowHeight: v.windowHeight, windowLine: 0.55,
            firstWindow: v.firstWindow, lastWindowFromTail: v.lastWindowFromTail
        )
        spec.engineMount = .rear
        spec.rearEngineInletFromTail = v.tailLength + v.engineLength * 0.15
        spec.rearEngineLine = 0.78
        spec.tTail = true
        return spec.build()
    }
}
