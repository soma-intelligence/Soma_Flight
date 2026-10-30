import Foundation

/// Embraer E170, E175, E190 and E195, and the E2 (E175-E2, E190-E2, E195-E2): the double-bubble 3.35 m
/// barrel, low swept wing with small canted winglets (raked tips on the E2), CF34 nacelles or the E2's bigger
/// PW1900G. Dimensions from Embraer's airport planning manuals.
enum EJet {
    private struct Variant { var length: Double; var height: Double; var plug: Double; var e2: Bool; var big: Bool }

    private static func variant(_ icao: String?) -> Variant {
        switch icao {
        case "E170": Variant(length: 29.90, height: 9.67, plug: -3.4, e2: false, big: false)
        case "E175", "E75L", "E75S": Variant(length: 31.68, height: 9.73, plug: -2.5, e2: false, big: false)
        case "E195": Variant(length: 38.65, height: 10.57, plug: 1.3, e2: false, big: true)
        case "E290": Variant(length: 36.25, height: 10.96, plug: 0, e2: true, big: true)
        case "E295": Variant(length: 41.51, height: 10.91, plug: 2.7, e2: true, big: true)
        default: Variant(length: 36.24, height: 10.57, plug: 0, e2: false, big: true)
        }
    }

    static func geometry(_ icao: String?) -> AircraftGeometry {
        let v = variant(icao)
        let L = v.length, plug = v.plug
        let rootLE = 14.0 + plug, rootChord = 5.4
        let doors: [AirlinerSpec.Door] = [
            .init(x: 4.3, width: 0.86, height: 1.85),
            .init(x: rootLE + 2.2, width: 0.51, height: 0.97, overwing: true),
            .init(x: L - 6.0, width: 0.76, height: 1.70),
        ]
        let engineD = v.e2 ? 2.15 : v.big ? 1.65 : 1.45
        return AirlinerSpec(
            family: .ejet, length: L, height: v.height, diameter: 3.35, bottom: v.e2 ? 1.40 : 1.25,
            nose: .ejet, noseLength: 5.0, tailLength: 9.8,
            fin: .swept, finRootLEFromTail: 8.2, finRootChord: 5.8, finTipChord: 2.2, finSweep: 4.8, finFillet: 2.6,
            tailplaneLEFromTail: 6.0, tailplaneChord: 3.0, tailplaneRun: 4.2, tailplaneRise: 0.95,
            wingRootLE: rootLE, wingRootChord: rootChord, wingTipChord: 1.2, wingSweep: v.big ? 6.6 : 6.0, wingRise: 1.3,
            winglet: v.e2 ? .raked : .canted, wingletHeight: v.e2 ? 0.4 : 1.2,
            engineDiameter: engineD, engineLength: v.e2 ? 4.0 : 3.4, engineClearance: v.e2 ? 0.48 : 0.50,
            engineInletFromWing: v.e2 ? -2.9 : -2.4, engineStyle: .plain,
            noseGearX: 3.8, mainGearX: rootLE + 3.9, noseTyre: 0.32, mainTyre: 0.52, mainAxles: 1, axleSpacing: 0,
            doors: doors, cargoDoors: [8.0 + plug * 0.4, L - 11.0], cargoDoorWidth: 1.1,
            windowPitch: 0.53, windowWidth: 0.27, windowHeight: 0.38, windowLine: 0.57,
            firstWindow: 5.4, lastWindowFromTail: 7.0
        ).build()
    }
}
