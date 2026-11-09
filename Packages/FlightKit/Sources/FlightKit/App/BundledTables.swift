import Foundation

/// The bundled tables the flight detail reads, decoded once each on first use. Warming them at launch,
/// off the main thread, keeps that first decode out of the first flight's opening animation.
public enum BundledTables {
    public static func warm() {
        Task.detached(priority: .utility) {
            _ = DestinationTable.bundled
            _ = LandmarkTable.bundled
            _ = AirlineContacts.bundled
            _ = AirportSizes.bundled
            _ = ConnectionRules.bundled
            _ = RegionNamer.bundled
        }
    }
}
