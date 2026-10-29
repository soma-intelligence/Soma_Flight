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
        // Pinned: a new release is taken on purpose, after its changelog is read.
        .package(url: "https://github.com/supabase/supabase-swift", exact: "2.55.5"),
    ],
    targets: [
        .target(
            name: "FlightKit",
            dependencies: [
                .product(name: "FlightCore", package: "FlightCoreFFI"),
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "FlightKitTests",
            dependencies: [
                "FlightKit",
                // The local-stack smoke test (INTEGRATION=1) signs a user in through the client.
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
