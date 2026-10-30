import Foundation

/// A380-800: the full-length double deck (an 8.4 m tall barrel with two rows of windows and doors), the
/// cockpit between the decks, four engines under a deep wing with tip fences, wing and body gear and the
/// huge fin. Dimensions from Airbus's A380 aircraft characteristics (airport planning) document.
enum A380 {
    static func geometry(_ icao: String?) -> AircraftGeometry {
        let L = 72.72, D = 8.41, yb = 2.0
        let rootLE = 25.0, rootChord = 17.4
        let main = (w: 1.07, h: 1.93)
        var doors: [AirlinerSpec.Door] = [9.6, 19.4, 32.8, 46.0, 58.2].map { .init(x: $0, width: main.w, height: main.h) }
        doors += [16.4, 38.2, 56.2].map { .init(x: $0, width: main.w, height: main.h, upper: true) }
        var spec = AirlinerSpec(
            family: .a380, length: L, height: 24.09, diameter: D, bottom: yb,
            nose: .a380, noseLength: 12.0, tailLength: 22.5,
            fin: .swept, finRootLEFromTail: 19.6, finRootChord: 15.2, finTipChord: 5.2, finSweep: 11.2, finFillet: 4.4,
            tailplaneLEFromTail: 16.2, tailplaneChord: 8.6, tailplaneRun: 13.0, tailplaneRise: 2.4,
            wingRootLE: rootLE, wingRootChord: rootChord, wingTipChord: 3.6, wingSweep: 25.0, wingRise: 3.8,
            winglet: .fence, wingletHeight: 1.5,
            engineDiameter: 3.4, engineLength: 6.2, engineClearance: 1.75,
            engineInletFromWing: 1.0, engineStyle: .plain,
            noseGearX: 6.2, mainGearX: rootLE + 12.6, noseTyre: 0.64, mainTyre: 0.71, mainAxles: 3, axleSpacing: 1.7,
            doors: doors, cargoDoors: [15.0, L - 20.6], cargoDoorWidth: 2.7,
            windowPitch: 0.533, windowWidth: 0.28, windowHeight: 0.40, windowLine: 0.42,
            firstWindow: 8.0, lastWindowFromTail: 12.2
        )
        // Both decks are windowed nose to tail: the upper row starts just behind the cockpit and runs as far
        // back as the main deck's.
        spec.upperDeck = .init(windowY: yb + 0.78 * D, firstWindow: 10.6, lastWindow: L - 12.8)
        spec.outboardEngine = (inletFromWing: 9.6, clearance: 2.9)
        spec.wingGear = (dx: -4.0, axles: 2)
        return spec.build()
    }
}
