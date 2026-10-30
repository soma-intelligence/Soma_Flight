import Foundation

/// A319, A320 and A321 (ceo and neo): one body, stretched by plugs fore and aft of the wing.
/// Dimensions from Airbus's A320 aircraft characteristics (airport planning) document.
enum A320Family {
    /// Overall length, plug ahead of the wing (relative to the A320), door pairs and neo engines.
    private struct Variant { var length: Double; var forwardPlug: Double; var fourDoors: Bool; var overwingExits: Int; var neo: Bool }

    private static func variant(_ icao: String?) -> Variant {
        switch icao {
        case "A318": Variant(length: 31.44, forwardPlug: -3.2, fourDoors: false, overwingExits: 1, neo: false)
        case "A319": Variant(length: 33.84, forwardPlug: -2.1, fourDoors: false, overwingExits: 1, neo: false)
        case "A19N": Variant(length: 33.84, forwardPlug: -2.1, fourDoors: false, overwingExits: 1, neo: true)
        case "A321": Variant(length: 44.51, forwardPlug: 4.27, fourDoors: true, overwingExits: 0, neo: false)
        case "A21N": Variant(length: 44.51, forwardPlug: 4.27, fourDoors: true, overwingExits: 0, neo: true)
        case "A20N": Variant(length: 37.57, forwardPlug: 0, fourDoors: false, overwingExits: 2, neo: true)
        default: Variant(length: 37.57, forwardPlug: 0, fourDoors: false, overwingExits: 2, neo: false)
        }
    }

    static func geometry(_ icao: String?) -> AircraftGeometry {
        let v = variant(icao)
        let L = v.length, plug = v.forwardPlug
        let rootLE = 13.6 + plug, rootChord = 6.6
        var doors: [AirlinerSpec.Door] = [.init(x: 6.25, width: 0.81, height: 1.85)]
        if v.fourDoors {
            doors.append(.init(x: rootLE - 2.4, width: 1.07, height: 1.85))
            doors.append(.init(x: rootLE + rootChord + 1.6, width: 1.07, height: 1.85))
        }
        for i in 0..<v.overwingExits {
            doors.append(.init(x: rootLE + 2.2 + Double(i) * 0.95, width: 0.51, height: 1.02, overwing: true))
        }
        doors.append(.init(x: L - 7.3, width: 0.81, height: 1.85))
        return AirlinerSpec(
            family: .a320, length: L, height: 11.76, diameter: 4.14, bottom: 1.85,
            nose: .airbus, noseLength: 6.0, tailLength: 11.4,
            finRootLEFromTail: 7.9, finRootChord: 6.3, finTipChord: 2.3, finSweep: 4.4, finFillet: 1.6,
            tailplaneLEFromTail: 6.3, tailplaneChord: 3.3, tailplaneRun: 3.4, tailplaneRise: 0.55,
            wingRootLE: rootLE, wingRootChord: rootChord, wingTipChord: 1.6, wingSweep: 8.2, wingRise: 1.1,
            winglet: .sharklet, wingletHeight: 2.43,
            engineDiameter: v.neo ? 2.3 : 2.05, engineLength: v.neo ? 4.6 : 4.3, engineClearance: v.neo ? 0.5 : 0.56,
            engineInletFromWing: v.neo ? -1.6 : -1.2, engineSpan: 0.3, engineStyle: .plain,
            noseGearX: 5.07, mainGearX: rootLE + 4.1, noseTyre: 0.38, mainTyre: 0.585, mainAxles: 1, axleSpacing: 0,
            doors: doors, cargoDoors: [9.2 + plug * 0.5, L - 12.6], cargoDoorWidth: 1.82,
            windowPitch: 0.533, windowWidth: 0.24, windowHeight: 0.34, windowLine: 0.60,
            firstWindow: 7.35, lastWindowFromTail: 8.2
        ).build()
    }
}
