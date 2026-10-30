import Foundation

/// A350-900 and -1000: the "panda mask" round the cockpit windows, curled wing tips, Trent XWB
/// nacelles, four-wheel (900) or six-wheel (1000) bogies. Dimensions from Airbus's A350 aircraft
/// characteristics (airport planning) document.
enum A350 {
    static func geometry(_ icao: String?) -> AircraftGeometry {
        let thousand = icao == "A35K"
        let L = thousand ? 73.79 : 66.80
        let plug = thousand ? 4.0 : 0
        let rootLE = 26.0 + plug, rootChord = 13.0
        let typeA = (w: 1.07, h: 1.93)
        let doors: [AirlinerSpec.Door] = [
            .init(x: 9.0, width: typeA.w, height: typeA.h),
            .init(x: rootLE - 3.4, width: typeA.w, height: typeA.h),
            .init(x: rootLE + rootChord + 2.0, width: typeA.w, height: typeA.h),
            .init(x: L - 10.2, width: typeA.w, height: typeA.h),
        ]
        return AirlinerSpec(
            family: .a350, length: L, height: thousand ? 17.08 : 17.05, diameter: 6.09, bottom: 2.35,
            nose: .a350, noseLength: 9.4, tailLength: 19.5,
            finRootLEFromTail: 14.2, finRootChord: 10.6, finTipChord: 3.9, finSweep: 7.4, finFillet: 3.6,
            tailplaneLEFromTail: 12.6, tailplaneChord: 5.6, tailplaneRun: 7.4, tailplaneRise: 0.9,
            wingRootLE: rootLE, wingRootChord: rootChord, wingTipChord: 1.8, wingSweep: 17.4, wingRise: 2.2,
            winglet: .curled, wingletHeight: 3.0,
            engineDiameter: 3.55, engineLength: 6.0, engineClearance: 0.8,
            engineInletFromWing: -0.6, engineSpan: 0.3, engineStyle: .plain,
            noseGearX: 5.6, mainGearX: rootLE + 8.2, noseTyre: 0.54, mainTyre: 0.68,
            mainAxles: thousand ? 3 : 2, axleSpacing: 1.5,
            doors: doors, cargoDoors: [13.6, L - 18.6], cargoDoorWidth: 2.7,
            windowPitch: 0.56, windowWidth: 0.30, windowHeight: 0.43, windowLine: 0.60,
            firstWindow: 10.3, lastWindowFromTail: 11.3
        ).build()
    }
}
