import Foundation

/// A350-900 and -1000: the "panda mask" round the cockpit windows, curled wing tips, Trent XWB
/// nacelles, four-wheel (900) or six-wheel (1000) bogies. Dimensions from Airbus's A350 aircraft
/// characteristics (airport planning) document.
enum A350 {
    static func geometry(_ icao: String?) -> AircraftGeometry {
        let thousand = icao == "A35K"
        let L = thousand ? 73.79 : 66.80
        let plug = thousand ? 4.0 : 0
        let rootLE = 26.7 + plug, rootChord = 13.0
        let typeA = (w: 1.07, h: 1.93)
        let doors: [AirlinerSpec.Door] = [
            .init(x: 9.0, width: typeA.w, height: typeA.h),
            .init(x: rootLE - 3.4, width: typeA.w, height: typeA.h),
            .init(x: rootLE + rootChord + 2.0, width: typeA.w, height: typeA.h),
            .init(x: L - 10.2, width: typeA.w, height: typeA.h),
        ]
        return AirlinerSpec(
            family: .a350, length: L, height: thousand ? 17.08 : 17.05, diameter: 6.09, bottom: 2.35,
            nose: .a350, noseLength: 9.8, tailLength: 19.5,
            fin: .curvedTip, finRootLEFromTail: 14.4, finRootChord: 10.8, finTipChord: 4.2, finSweep: 7.4, finFillet: 3.4,
            tailplaneLEFromTail: 12.8, tailplaneChord: 5.8, tailplaneRun: 9.6, tailplaneRise: 1.8,
            wingRootLE: rootLE, wingRootChord: rootChord, wingTipChord: 1.8, wingSweep: 17.5, wingRise: 3.0,
            winglet: .curled, wingletHeight: 2.6,
            engineDiameter: 3.6, engineLength: 6.0, engineClearance: 0.8,
            engineInletFromWing: -4.3, engineStyle: .plain,
            noseGearX: 5.6, mainGearX: rootLE + 7.6, noseTyre: 0.54, mainTyre: 0.68,
            mainAxles: thousand ? 3 : 2, axleSpacing: 1.5,
            doors: doors, cargoDoors: [13.6, L - 18.6], cargoDoorWidth: 2.7,
            windowPitch: 0.56, windowWidth: 0.30, windowHeight: 0.43, windowLine: 0.60,
            firstWindow: 10.3, lastWindowFromTail: 11.3
        ).build()
    }
}
