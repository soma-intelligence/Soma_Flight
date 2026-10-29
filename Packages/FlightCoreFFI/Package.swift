// swift-tools-version: 6.0
// Swift binding of the flightcore Rust crate (core/flightcore-ffi), built by
// core/scripts/build-xcframework.sh. Sources/FlightCore/FlightCore.swift and
// FlightCoreFFI.xcframework are generated; do not edit them by hand.
import PackageDescription

let package = Package(
    name: "FlightCoreFFI",
    // .v26 needs PackageDescription 6.2; the string form keeps tools 6.0.
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "FlightCore", targets: ["FlightCore"]),
    ],
    targets: [
        .binaryTarget(name: "FlightCoreFFI", path: "FlightCoreFFI.xcframework"),
        .target(name: "FlightCore", dependencies: ["FlightCoreFFI"]),
        .testTarget(
            name: "FlightCoreTests",
            dependencies: ["FlightCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
