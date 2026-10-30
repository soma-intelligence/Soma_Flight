import Foundation

/// 767-200, -300 and -400: the semi-wide 5 m barrel between the 757 and the 777, the 757's nose, CF6 or
/// PW4000 nacelles, four-wheel bogies, blended winglets on the -300ER and raked tips on the -400.
/// Dimensions from Boeing's 767 airplane characteristics for airport planning.
enum B767 {
    private struct Variant { var length: Double; var height: Double; var plug: Double; var winglet: AirlinerSpec.Winglet }

    private static func variant(_ icao: String?) -> Variant {
        switch icao {
        case "B762": Variant(length: 48.51, height: 15.85, plug: -3.2, winglet: .none)
        case "B764": Variant(length: 61.37, height: 16.87, plug: 3.3, winglet: .raked)
        default: Variant(length: 54.94, height: 15.85, plug: 0, winglet: .blended)
        }
    }

    static func geometry(_ icao: String?) -> AircraftGeometry {
        let v = variant(icao)
        let L = v.length, plug = v.plug
        let rootLE = 21.8 + plug, rootChord = 9.6
        let doors: [AirlinerSpec.Door] = [
            .init(x: 7.0, width: 1.07, height: 1.88),
            .init(x: rootLE - 3.8, width: 1.07, height: 1.88),
            .init(x: rootLE + 3.4, width: 0.51, height: 0.97, overwing: true),
            .init(x: L - 8.6, width: 1.07, height: 1.88),
        ]
        return AirlinerSpec(
            family: .b767, length: L, height: v.height, diameter: 5.03, bottom: 1.95,
            nose: .b757, noseLength: 7.8, tailLength: 15.2,
            fin: .swept, finRootLEFromTail: 12.4, finRootChord: 9.0, finTipChord: 3.2, finSweep: 7.4, finFillet: 2.6,
            tailplaneLEFromTail: 9.8, tailplaneChord: 4.8, tailplaneRun: 7.4, tailplaneRise: 1.6,
            wingRootLE: rootLE, wingRootChord: rootChord, wingTipChord: 2.0, wingSweep: 13.0, wingRise: 2.4,
            winglet: v.winglet, wingletHeight: v.winglet == .raked ? 0.8 : 3.0,
            engineDiameter: 2.85, engineLength: 5.6, engineClearance: 0.68,
            engineInletFromWing: -3.6, engineStyle: .plain,
            noseGearX: 4.8, mainGearX: rootLE + 6.3, noseTyre: 0.46, mainTyre: 0.58, mainAxles: 2, axleSpacing: 1.42,
            doors: doors, cargoDoors: [11.2, L - 15.2], cargoDoorWidth: 1.75,
            windowPitch: 0.508, windowWidth: 0.26, windowHeight: 0.38, windowLine: 0.58,
            firstWindow: 8.2, lastWindowFromTail: 9.8
        ).build()
    }
}
