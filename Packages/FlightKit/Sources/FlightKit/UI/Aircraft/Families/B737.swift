import Foundation

/// 737 Classic and Next Generation (-200 to -900): the flat-bottomed CFM56 nacelles, the tall fin with
/// its long dorsal fillet and, on the NG, blended winglets. Dimensions from Boeing's 737 airplane
/// characteristics for airport planning.
enum B737 {
    private struct Variant { var length: Double; var height: Double; var forwardPlug: Double; var overwingExits: Int; var classic: Bool }

    private static func variant(_ icao: String?) -> Variant {
        switch icao {
        case "B732": Variant(length: 30.53, height: 11.28, forwardPlug: -5.0, overwingExits: 1, classic: true)
        case "B733": Variant(length: 33.40, height: 11.13, forwardPlug: -3.3, overwingExits: 1, classic: true)
        case "B734": Variant(length: 36.45, height: 11.13, forwardPlug: -1.6, overwingExits: 2, classic: true)
        case "B735": Variant(length: 31.01, height: 11.13, forwardPlug: -4.6, overwingExits: 1, classic: true)
        case "B736": Variant(length: 31.24, height: 12.57, forwardPlug: -4.5, overwingExits: 1, classic: false)
        case "B737": Variant(length: 33.63, height: 12.55, forwardPlug: -3.2, overwingExits: 1, classic: false)
        case "B739": Variant(length: 42.11, height: 12.55, forwardPlug: 1.5, overwingExits: 2, classic: false)
        default: Variant(length: 39.47, height: 12.55, forwardPlug: 0, overwingExits: 2, classic: false)
        }
    }

    static func geometry(_ icao: String?) -> AircraftGeometry {
        let v = variant(icao)
        return spec(length: v.length, height: v.height, forwardPlug: v.forwardPlug, overwingExits: v.overwingExits,
                    winglet: v.classic ? .none : .blended, family: .b737).build()
    }

    /// The shared 737 body; the MAX reuses it with its own engines, tail cone and wing tips.
    static func spec(length L: Double, height: Double, forwardPlug plug: Double, overwingExits: Int,
                     winglet: AirlinerSpec.Winglet, family: AircraftFamily) -> AirlinerSpec {
        let rootLE = 14.0 + plug
        var doors: [AirlinerSpec.Door] = [.init(x: 5.45, width: 0.86, height: 1.83)]
        for i in 0..<overwingExits {
            doors.append(.init(x: rootLE + 2.3 + Double(i) * 0.95, width: 0.51, height: 0.97, overwing: true))
        }
        doors.append(.init(x: L - 6.4, width: 0.76, height: 1.83))
        return AirlinerSpec(
            family: family, length: L, height: height, diameter: 4.01, bottom: 1.25,
            nose: .b737, noseLength: 5.8, tailLength: 11.0,
            finRootLEFromTail: 8.9, finRootChord: 6.5, finTipChord: 2.3, finSweep: 5.6, finFillet: 5.5,
            tailplaneLEFromTail: 6.4, tailplaneChord: 3.3, tailplaneRun: 3.3, tailplaneRise: 0.55,
            wingRootLE: rootLE, wingRootChord: 7.0, wingTipChord: 1.25, wingSweep: 7.4, wingRise: 1.2,
            winglet: winglet, wingletHeight: 2.49,
            engineDiameter: 1.95, engineLength: 3.9, engineClearance: 0.46,
            engineInletFromWing: -1.6, engineSpan: 0.3, engineStyle: .flatBottom,
            noseGearX: 4.35, mainGearX: rootLE + 5.9, noseTyre: 0.34, mainTyre: 0.56, mainAxles: 1, axleSpacing: 0,
            doors: doors, cargoDoors: [8.7 + plug * 0.4, L - 11.6], cargoDoorWidth: 1.22,
            windowPitch: 0.508, windowWidth: 0.25, windowHeight: 0.36, windowLine: 0.58,
            firstWindow: 6.6, lastWindowFromTail: 7.4
        )
    }
}
