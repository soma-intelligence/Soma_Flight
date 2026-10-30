import Foundation

/// 737 MAX 7, 8, 9 and 10: the 737 body with the bigger round LEAP-1B nacelles (chevroned, set further
/// forward and higher), the taller nose gear and the split scimitar tips. Dimensions from Boeing's 737
/// MAX airplane characteristics for airport planning.
enum B737Max {
    private static func variant(_ icao: String?) -> (length: Double, height: Double, plug: Double, exits: Int) {
        switch icao {
        case "B37M": (35.56, 12.31, -2.1, 1)
        case "B39M": (42.16, 12.29, 1.5, 2)
        case "B3XM": (43.80, 12.29, 2.4, 2)
        default: (39.52, 12.29, 0, 2)
        }
    }

    static func geometry(_ icao: String?) -> AircraftGeometry {
        let v = variant(icao)
        var spec = B737.spec(length: v.length, height: v.height, forwardPlug: v.plug, overwingExits: v.exits,
                             winglet: .splitScimitar, family: .b737max)
        spec.engineDiameter = 2.15
        spec.engineLength = 4.5
        spec.engineClearance = 0.43
        spec.engineInletFromWing = -2.2
        spec.engineStyle = .chevron
        spec.wingletHeight = 2.0
        spec.bottom = 1.32
        spec.tailLength = 11.6
        return spec.build()
    }
}
