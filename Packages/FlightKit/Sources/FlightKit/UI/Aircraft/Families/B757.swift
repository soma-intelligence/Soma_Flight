import Foundation

/// 757-200 and -300: the long narrow 737-width barrel on tall gear, a pointed nose, long-duct RB211-535
/// (or PW2000) nacelles, four-wheel bogies and blended winglets. Dimensions from Boeing's 757 airplane
/// characteristics for airport planning.
enum B757 {
    static func geometry(_ icao: String?) -> AircraftGeometry {
        let three = icao == "B753"
        let L = three ? 54.47 : 47.32
        let plug = three ? 3.4 : 0
        let rootLE = 18.6 + plug, rootChord = 7.6
        var doors: [AirlinerSpec.Door] = [
            .init(x: 5.5, width: 0.84, height: 1.83),
            .init(x: 12.4 + plug * 0.7, width: 0.84, height: 1.83),
        ]
        for i in 0..<2 {
            doors.append(.init(x: rootLE + 2.2 + Double(i) * 0.95, width: 0.51, height: 0.97, overwing: true))
        }
        if three { doors.append(.init(x: rootLE + rootChord + 3.6, width: 0.76, height: 1.52)) }
        doors.append(.init(x: L - 7.8, width: 0.84, height: 1.83))
        return AirlinerSpec(
            family: .b757, length: L, height: 13.56, diameter: 4.01, bottom: 1.95,
            nose: .b757, noseLength: 6.6, tailLength: 12.8,
            fin: .swept, finRootLEFromTail: 10.6, finRootChord: 7.4, finTipChord: 2.5, finSweep: 6.6, finFillet: 2.4,
            tailplaneLEFromTail: 7.8, tailplaneChord: 4.0, tailplaneRun: 5.6, tailplaneRise: 1.3,
            wingRootLE: rootLE, wingRootChord: rootChord, wingTipChord: 1.6, wingSweep: 9.4, wingRise: 1.9,
            winglet: .blended, wingletHeight: 2.5,
            engineDiameter: 2.45, engineLength: 5.6, engineClearance: 0.72,
            engineInletFromWing: -3.4, engineStyle: .longDuct,
            noseGearX: 4.3, mainGearX: rootLE + 5.4, noseTyre: 0.42, mainTyre: 0.57, mainAxles: 2, axleSpacing: 1.14,
            doors: doors, cargoDoors: [9.0 + plug * 0.4, L - 14.0], cargoDoorWidth: 1.4,
            windowPitch: 0.508, windowWidth: 0.25, windowHeight: 0.36, windowLine: 0.58,
            firstWindow: 6.6, lastWindowFromTail: 8.6
        ).build()
    }
}
