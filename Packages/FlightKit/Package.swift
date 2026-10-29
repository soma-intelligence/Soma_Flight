// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlightKit",
    // .v26 needs PackageDescription 6.2; the string form keeps tools 6.0.
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "FlightKit", targets: ["FlightKit"]),
    ],
    dependencies: [
        .package(path: "../FlightCoreFFI"),
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "FlightKit",
            dependencies: [
                .product(name: "FlightCore", package: "FlightCoreFFI"),
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "FlightKitTests",
            dependencies: ["FlightKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
