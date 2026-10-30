import Foundation

/// Bombardier (Mitsubishi) CRJ100/200, 700, 900 and 1000: a slim 2.69 m barrel close to the ground, the
/// long pointed nose, a clean swept wing with small winglets, CF34 engines on the aft fuselage and a T-tail.
/// Dimensions from the CRJ airport planning manuals.
enum CRJ {
    private struct Variant { var length: Double; var height: Double; var plug: Double; var two: Bool }

    private static func variant(_ icao: String?) -> Variant {
        switch icao {
        case "CRJ1", "CRJ2": Variant(length: 26.77, height: 6.22, plug: -5.4, two: true)
        case "CRJ7": Variant(length: 32.51, height: 7.57, plug: -2.4, two: false)
        case "CRJX": Variant(length: 39.13, height: 7.51, plug: 1.6, two: false)
        default: Variant(length: 36.40, height: 7.51, plug: 0, two: false)
        }
    }

    static func geometry(_ icao: String?) -> AircraftGeometry {
        let v = variant(icao)
        let L = v.length, plug = v.plug
        let rootLE = 15.4 + plug, rootChord = 4.4
        var doors: [AirlinerSpec.Door] = [.init(x: 2.9, width: 0.86, height: 1.75)]
        for i in 0..<(v.two ? 1 : 2) {
            doors.append(.init(x: rootLE + 1.2 + Double(i) * 0.9, width: 0.51, height: 0.92, overwing: true))
        }
        var spec = AirlinerSpec(
            family: .crj, length: L, height: v.height, diameter: 2.69, bottom: v.two ? 0.72 : 0.92,
            nose: .crj, noseLength: 5.0, tailLength: 9.0,
            fin: .swept, finRootLEFromTail: v.two ? 6.0 : 6.6, finRootChord: v.two ? 4.4 : 4.8, finTipChord: v.two ? 2.2 : 2.4,
            finSweep: v.two ? 3.0 : 3.6, finFillet: 1.8,
            tailplaneLEFromTail: 0, tailplaneChord: 2.7, tailplaneRun: v.two ? 2.2 : 2.6, tailplaneRise: 0.30,
            wingRootLE: rootLE, wingRootChord: rootChord, wingTipChord: 1.0, wingSweep: v.two ? 4.6 : 5.4, wingRise: 1.0,
            winglet: .canted, wingletHeight: v.two ? 0.8 : 1.0,
            engineDiameter: v.two ? 1.30 : 1.45, engineLength: v.two ? 3.2 : 3.6, engineClearance: 0,
            engineInletFromWing: 0, engineStyle: .plain,
            noseGearX: 2.6, mainGearX: rootLE + 3.1, noseTyre: 0.29, mainTyre: 0.44, mainAxles: 1, axleSpacing: 0,
            doors: doors, cargoDoors: [L - 9.0 - (v.two ? 0 : 0.6)], cargoDoorWidth: 0.9,
            windowPitch: 0.51, windowWidth: 0.23, windowHeight: 0.32, windowLine: 0.57,
            firstWindow: 3.9, lastWindowFromTail: v.two ? 9.6 : 10.6
        )
        spec.engineMount = .rear
        spec.rearEngineInletFromTail = v.two ? 9.0 : 10.0
        spec.rearEngineLine = 0.80
        spec.tTail = true
        return spec.build()
    }
}
