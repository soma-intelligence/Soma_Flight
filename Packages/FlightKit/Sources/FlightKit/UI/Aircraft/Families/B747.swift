import Foundation

/// 747-400, 747-8 and 747SP: the upper deck hump over the forward fuselage (longer on the -8, short on the
/// SP), four engines, wing and body gear, canted winglets on the -400 and raked tips with chevroned GEnx on
/// the -8. Dimensions from Boeing's 747 airplane characteristics for airport planning.
enum B747 {
    private struct Variant {
        var length: Double; var height: Double; var plug: Double; var humpEnd: Double
        var winglet: AirlinerSpec.Winglet; var eight: Bool
    }

    private static func variant(_ icao: String?) -> Variant {
        switch icao {
        case "B748": Variant(length: 76.25, height: 19.35, plug: 4.1, humpEnd: 27.6, winglet: .raked, eight: true)
        case "B74S": Variant(length: 56.31, height: 19.94, plug: -6.2, humpEnd: 15.8, winglet: .none, eight: false)
        default: Variant(length: 70.66, height: 19.41, plug: 0, humpEnd: 23.5, winglet: .canted, eight: false)
        }
    }

    static func geometry(_ icao: String?) -> AircraftGeometry {
        let v = variant(icao)
        let L = v.length, plug = v.plug, D = 6.5, yb = 2.3
        let rootLE = 27.4 + plug, rootChord = 15.0
        let typeA = (w: 1.07, h: 1.93)
        var doors: [AirlinerSpec.Door] = [
            .init(x: 7.9, width: typeA.w, height: typeA.h),
            .init(x: 17.6 + plug * 0.6, width: typeA.w, height: typeA.h),
            .init(x: rootLE + 0.4, width: typeA.w, height: typeA.h),
            .init(x: rootLE + rootChord + 1.8, width: typeA.w, height: typeA.h),
            .init(x: L - 14.4, width: typeA.w, height: typeA.h),
        ]
        if v.humpEnd > 20 { doors.append(.init(x: v.humpEnd - 3.4, width: 0.81, height: 1.6, upper: true)) }
        var spec = AirlinerSpec(
            family: .b747, length: L, height: v.height, diameter: D, bottom: yb,
            nose: .b747, noseLength: 10.6, tailLength: 19.0,
            fin: .swept, finRootLEFromTail: 15.6, finRootChord: 12.2, finTipChord: 4.4, finSweep: 9.6, finFillet: 3.4,
            tailplaneLEFromTail: 12.6, tailplaneChord: 7.0, tailplaneRun: 10.2, tailplaneRise: 2.0,
            wingRootLE: rootLE, wingRootChord: rootChord, wingTipChord: 3.4, wingSweep: 22.0, wingRise: 3.4,
            winglet: v.winglet, wingletHeight: v.winglet == .raked ? 0.9 : 1.9,
            engineDiameter: v.eight ? 3.2 : 2.75, engineLength: v.eight ? 6.0 : 5.5, engineClearance: v.eight ? 1.05 : 1.3,
            engineInletFromWing: v.eight ? -0.6 : 0.0, engineStyle: v.eight ? .chevron : .plain,
            noseGearX: 6.6, mainGearX: rootLE + 7.2, noseTyre: 0.62, mainTyre: 0.62, mainAxles: 2, axleSpacing: 1.47,
            doors: doors, cargoDoors: [14.0 + plug * 0.5, L - 18.4], cargoDoorWidth: 2.7,
            windowPitch: 0.508, windowWidth: 0.26, windowHeight: 0.38, windowLine: 0.56,
            firstWindow: 8.9, lastWindowFromTail: 12.8
        )
        spec.hump = .init(rise: 1.75, end: v.humpEnd, fair: 7.4)
        spec.upperDeck = .init(windowY: yb + D + 0.35, firstWindow: 11.6, lastWindow: v.humpEnd - 0.4)
        spec.outboardEngine = (inletFromWing: v.eight ? 7.0 : 7.4, clearance: v.eight ? 2.2 : 2.45)
        spec.wingGear = (dx: -3.4, axles: 2)
        return spec.build()
    }
}
