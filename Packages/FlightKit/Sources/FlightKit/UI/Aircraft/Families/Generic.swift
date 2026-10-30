import Foundation

/// The bodies used until a family has its own drawing: a plain twin-engined narrowbody and widebody
/// with simple wing tips, sized like the commonest aircraft of each kind.
public enum Generic {
    public static let narrowbody: AircraftGeometry = {
        var spec = B737.spec(length: 38.0, height: 12.0, forwardPlug: -0.3, overwingExits: 2, winglet: .none, family: .other)
        spec.nose = .airbus
        spec.bottom = 1.7
        spec.engineDiameter = 2.05
        spec.engineLength = 4.2
        spec.engineClearance = 0.55
        spec.engineStyle = .plain
        spec.finFillet = 1.8
        return spec.build()
    }()

    public static let widebody: AircraftGeometry = {
        var spec = B787.spec(length: 64.0, height: 17.5, forwardPlug: 0.5)
        spec.family = .other
        spec.nose = .b777
        spec.winglet = .none
        spec.engineStyle = .plain
        spec.windowPitch = 0.533
        spec.windowWidth = 0.28
        spec.windowHeight = 0.40
        return spec.build()
    }()
}
