// FlightStatus and DelayLevel live in FlightActivityKit, the small module the widget extension links.
// Re-exported so the app, the stores and the tests keep seeing them through `import FlightKit`.
@_exported import FlightActivityKit

/// FlightCore has a `FlightStatus` too; inside FlightKit the name means this one, as it did before the move.
public typealias FlightStatus = FlightActivityKit.FlightStatus
