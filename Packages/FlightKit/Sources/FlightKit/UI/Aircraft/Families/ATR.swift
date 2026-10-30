import Foundation

/// ATR 42 and ATR 72 (-200 to -600): a high wing on the crown, PW100 turboprops in long nacelles with
/// six-blade propellers on the -600 series, main gear in fuselage sponsons, the upswept tail and a T-tail
/// with a long dorsal fillet. The passenger door is at the back; the cargo door is up front. Dimensions from
/// ATR's airport planning manuals.
enum ATR {
    static func geometry(_ icao: String?) -> AircraftGeometry {
        let fortyTwo = ["AT42", "AT43", "AT44", "AT45", "AT46"].contains(icao ?? "")
        let L = fortyTwo ? 22.67 : 27.17
        let plug = fortyTwo ? -2.4 : 0
        let rootLE = 11.4 + plug, rootChord = 2.6
        let doors: [AirlinerSpec.Door] = [
            .init(x: 4.1, width: 1.28, height: 1.50),
            .init(x: L - 5.6, width: 0.72, height: 1.75),
        ]
        var spec = AirlinerSpec(
            family: .atr, length: L, height: fortyTwo ? 7.59 : 7.65, diameter: 2.60, bottom: 0.95,
            nose: .atr, noseLength: 3.8, tailLength: 8.8,
            fin: .swept, finRootLEFromTail: 5.8, finRootChord: 4.0, finTipChord: 2.3, finSweep: 2.6, finFillet: 4.0,
            tailplaneLEFromTail: 0, tailplaneChord: 2.3, tailplaneRun: 2.0, tailplaneRise: 0.25,
            wingRootLE: rootLE, wingRootChord: rootChord, wingTipChord: 1.5, wingSweep: 0.5, wingRise: 0.22,
            winglet: .none, wingletHeight: 0,
            engineDiameter: 1.25, engineLength: 5.4, engineClearance: 0,
            engineInletFromWing: -2.3, engineStyle: .plain,
            noseGearX: 2.2, mainGearX: rootLE + 1.5, noseTyre: 0.30, mainTyre: 0.42, mainAxles: 1, axleSpacing: 0,
            doors: doors, cargoDoors: [], cargoDoorWidth: 0,
            windowPitch: 0.762, windowWidth: 0.25, windowHeight: 0.34, windowLine: 0.58,
            firstWindow: 5.5, lastWindowFromTail: 6.6
        )
        spec.wingMount = .high
        spec.engineMount = .turboprop
        spec.propellerDiameter = 3.93
        spec.tTail = true
        return spec.build()
    }
}
