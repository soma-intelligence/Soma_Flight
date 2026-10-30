import Foundation

/// 777-200, -200ER, -200LR, -300, -300ER and 777X: the big round GE90 (or Trent/PW) nacelles, six-wheel
/// bogies, the blade tail cone and, on the -300ER, -200LR and 777X, raked tips. Dimensions from Boeing's
/// 777 airplane characteristics for airport planning.
enum B777 {
    private static func variant(_ icao: String?) -> (length: Double, plug: Double, raked: Bool, fiveDoors: Bool) {
        switch icao {
        case "B772": (63.73, -5.33, false, false)
        case "B77L": (63.73, -5.33, true, false)
        case "B773": (73.86, 0, false, true)
        case "B778": (69.79, -2.2, true, true)
        case "B779": (76.72, 1.5, true, true)
        default: (73.86, 0, true, true)
        }
    }

    static func geometry(_ icao: String?) -> AircraftGeometry {
        let v = variant(icao)
        let L = v.length, plug = v.plug
        let rootLE = 27.6 + plug, rootChord = 13.4
        let typeA = (w: 1.07, h: 1.88)
        var doors: [AirlinerSpec.Door] = [
            .init(x: 9.3, width: typeA.w, height: typeA.h),
            .init(x: rootLE - 6.4, width: typeA.w, height: typeA.h),
            .init(x: rootLE + rootChord + 1.4, width: typeA.w, height: typeA.h),
        ]
        if v.fiveDoors { doors.append(.init(x: L - 21.0, width: typeA.w, height: typeA.h)) }
        doors.append(.init(x: L - 10.8, width: typeA.w, height: typeA.h))
        return AirlinerSpec(
            family: .b777, length: L, height: 18.5, diameter: 6.2, bottom: 2.35,
            nose: .b777, noseLength: 9.6, tailLength: 20.0,
            finRootLEFromTail: 15.4, finRootChord: 11.2, finTipChord: 3.9, finSweep: 7.8, finFillet: 3.0,
            tailplaneLEFromTail: 13.6, tailplaneChord: 6.0, tailplaneRun: 7.6, tailplaneRise: 1.0,
            wingRootLE: rootLE, wingRootChord: rootChord, wingTipChord: 2.4, wingSweep: 17.0, wingRise: 2.3,
            winglet: v.raked ? .raked : .none, wingletHeight: 0.7,
            engineDiameter: 3.95, engineLength: 7.4, engineClearance: 0.85,
            engineInletFromWing: -0.8, engineSpan: 0.3, engineStyle: .plain,
            noseGearX: 5.6, mainGearX: rootLE + 9.2, noseTyre: 0.55, mainTyre: 0.67, mainAxles: 3, axleSpacing: 1.47,
            doors: doors, cargoDoors: [14.6, L - 19.2], cargoDoorWidth: 2.7,
            windowPitch: 0.533, windowWidth: 0.28, windowHeight: 0.40, windowLine: 0.60,
            firstWindow: 10.5, lastWindowFromTail: 11.9
        ).build()
    }
}
