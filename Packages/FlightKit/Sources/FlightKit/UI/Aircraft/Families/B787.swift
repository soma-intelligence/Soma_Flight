import Foundation

/// 787-8, -9 and -10: the long sleek nose with four cockpit panes, tall windows, chevroned GEnx or
/// Trent 1000 nacelles, four-wheel bogies and raked tips. Dimensions from Boeing's 787 airplane
/// characteristics for airport planning.
enum B787 {
    private static func variant(_ icao: String?) -> (length: Double, height: Double, plug: Double) {
        switch icao {
        case "B788": (56.72, 16.92, -3.0)
        case "B78X": (68.28, 17.02, 2.7)
        default: (62.81, 17.02, 0)
        }
    }

    static func geometry(_ icao: String?) -> AircraftGeometry {
        let v = variant(icao)
        return spec(length: v.length, height: v.height, forwardPlug: v.plug).build()
    }

    static func spec(length L: Double, height: Double, forwardPlug plug: Double) -> AirlinerSpec {
        let rootLE = 24.8 + plug, rootChord = 11.6
        let typeA = (w: 1.07, h: 1.93)
        let doors: [AirlinerSpec.Door] = [
            .init(x: 8.7, width: typeA.w, height: typeA.h),
            .init(x: rootLE - 3.4, width: typeA.w, height: typeA.h),
            .init(x: rootLE + rootChord + 2.2, width: typeA.w, height: typeA.h),
            .init(x: L - 9.6, width: typeA.w, height: typeA.h),
        ]
        return AirlinerSpec(
            family: .b787, length: L, height: height, diameter: 5.97, bottom: 2.35,
            nose: .b787, noseLength: 10.2, tailLength: 18.5,
            finRootLEFromTail: 13.6, finRootChord: 10.0, finTipChord: 3.5, finSweep: 7.4, finFillet: 4.6,
            tailplaneLEFromTail: 12.2, tailplaneChord: 5.0, tailplaneRun: 6.8, tailplaneRise: 0.85,
            wingRootLE: rootLE, wingRootChord: rootChord, wingTipChord: 1.5, wingSweep: 16.6, wingRise: 2.4,
            winglet: .raked, wingletHeight: 0.9,
            engineDiameter: 3.3, engineLength: 5.7, engineClearance: 0.85,
            engineInletFromWing: -0.2, engineSpan: 0.3, engineStyle: .chevron,
            noseGearX: 5.4, mainGearX: rootLE + 6.8, noseTyre: 0.52, mainTyre: 0.64, mainAxles: 2, axleSpacing: 1.45,
            doors: doors, cargoDoors: [12.6, L - 17.6], cargoDoorWidth: 2.7,
            windowPitch: 0.61, windowWidth: 0.30, windowHeight: 0.47, windowLine: 0.60,
            firstWindow: 9.9, lastWindowFromTail: 10.7
        )
    }
}
