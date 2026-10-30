import Foundation

/// A330-200, -300 and the neo -800 and -900: the A300/A340 barrel, canted winglets on the ceo, the neo's
/// tall curved sharklet-style tips and bigger Trent 7000 nacelles, four-wheel bogies. Dimensions from
/// Airbus's A330 and A330neo aircraft characteristics (airport planning) documents.
enum A330 {
    private struct Variant { var length: Double; var height: Double; var plug: Double; var neo: Bool }

    private static func variant(_ icao: String?) -> Variant {
        switch icao {
        case "A332": Variant(length: 58.82, height: 17.39, plug: -3.2, neo: false)
        case "A338": Variant(length: 58.82, height: 17.39, plug: -3.2, neo: true)
        case "A339": Variant(length: 63.66, height: 16.79, plug: 0, neo: true)
        default: Variant(length: 63.69, height: 16.79, plug: 0, neo: false)
        }
    }

    static func geometry(_ icao: String?) -> AircraftGeometry {
        let v = variant(icao)
        let L = v.length, plug = v.plug
        let rootLE = 24.8 + plug, rootChord = 11.6
        let typeA = (w: 1.07, h: 1.93)
        let doors: [AirlinerSpec.Door] = [
            .init(x: 8.4, width: typeA.w, height: typeA.h),
            .init(x: rootLE - 4.4, width: typeA.w, height: typeA.h),
            .init(x: rootLE + rootChord + 1.6, width: 0.81, height: 1.85),
            .init(x: L - 9.8, width: typeA.w, height: typeA.h),
        ]
        return AirlinerSpec(
            family: .a330, length: L, height: v.height, diameter: 5.64, bottom: 2.15,
            nose: .airbus, noseLength: 8.8, tailLength: 18.0,
            fin: .swept, finRootLEFromTail: 13.6, finRootChord: 10.0, finTipChord: 3.6, finSweep: 7.6, finFillet: 2.8,
            tailplaneLEFromTail: 11.6, tailplaneChord: 5.4, tailplaneRun: 9.0, tailplaneRise: 1.7,
            wingRootLE: rootLE, wingRootChord: rootChord, wingTipChord: 2.0, wingSweep: 16.4, wingRise: 2.9,
            winglet: v.neo ? .sharklet : .canted, wingletHeight: v.neo ? 3.4 : 2.5,
            engineDiameter: v.neo ? 3.35 : 3.0, engineLength: v.neo ? 6.0 : 5.7, engineClearance: v.neo ? 0.68 : 0.78,
            engineInletFromWing: v.neo ? -4.4 : -4.0, engineStyle: .plain,
            noseGearX: 5.1, mainGearX: rootLE + 7.0, noseTyre: 0.52, mainTyre: 0.63, mainAxles: 2, axleSpacing: 1.4,
            doors: doors, cargoDoors: [12.4, L - 17.4], cargoDoorWidth: 2.7,
            windowPitch: 0.533, windowWidth: 0.28, windowHeight: 0.40, windowLine: 0.60,
            firstWindow: 9.6, lastWindowFromTail: 10.8
        ).build()
    }
}
