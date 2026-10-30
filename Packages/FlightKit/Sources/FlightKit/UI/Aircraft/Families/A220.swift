import Foundation

/// A220-100 and -300 (ex CSeries): a slim 3.7 m barrel with big windows, large PW1500G geared turbofans hung
/// well forward, plain wing tips and a tall swept fin with a long fillet. Dimensions from Airbus's A220
/// aircraft characteristics (airport planning) documents.
enum A220 {
    static func geometry(_ icao: String?) -> AircraftGeometry {
        let hundred = icao == "BCS1"
        let L = hundred ? 35.00 : 38.71
        let plug = hundred ? -2.2 : 0
        let rootLE = 15.6 + plug, rootChord = 5.6
        var doors: [AirlinerSpec.Door] = [.init(x: 4.55, width: 0.81, height: 1.85)]
        for i in 0..<(hundred ? 1 : 2) {
            doors.append(.init(x: rootLE + 1.9 + Double(i) * 0.95, width: 0.51, height: 0.97, overwing: true))
        }
        doors.append(.init(x: L - 6.3, width: 0.81, height: 1.85))
        return AirlinerSpec(
            family: .a220, length: L, height: hundred ? 11.50 : 11.51, diameter: 3.70, bottom: 1.50,
            nose: .a220, noseLength: 5.6, tailLength: 11.0,
            fin: .swept, finRootLEFromTail: 8.8, finRootChord: 6.3, finTipChord: 2.4, finSweep: 5.0, finFillet: 3.0,
            tailplaneLEFromTail: 6.3, tailplaneChord: 3.2, tailplaneRun: 4.4, tailplaneRise: 1.0,
            wingRootLE: rootLE, wingRootChord: rootChord, wingTipChord: 1.3, wingSweep: 7.6, wingRise: 1.5,
            winglet: .raked, wingletHeight: 0.35,
            engineDiameter: 2.2, engineLength: 4.5, engineClearance: 0.52,
            engineInletFromWing: -3.0, engineStyle: .plain,
            noseGearX: 4.3, mainGearX: rootLE + 3.7, noseTyre: 0.35, mainTyre: 0.56, mainAxles: 1, axleSpacing: 0,
            doors: doors, cargoDoors: [8.6 + plug * 0.5, L - 11.4], cargoDoorWidth: 1.3,
            windowPitch: 0.53, windowWidth: 0.28, windowHeight: 0.42, windowLine: 0.58,
            firstWindow: 5.7, lastWindowFromTail: 7.5
        ).build()
    }
}
