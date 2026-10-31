// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlightKit",
    // .v26 needs PackageDescription 6.2; the string form keeps tools 6.0.
    platforms: [.iOS("26.0"), .macOS("26.0"), .watchOS("26.0")],
    products: [
        .library(name: "FlightKit", targets: ["FlightKit"]),
        // What the widget extension links: the Live Activity attributes and views, no Supabase or MapKit.
        .library(name: "FlightActivityKit", targets: ["FlightActivityKit"]),
        // What the Apple Watch app and its complications link: the snapshot from the phone and the watch's
        // models, over FlightActivityKit. No Supabase: the watch only hears from the phone in v1.
        .library(name: "FlightWatchKit", targets: ["FlightWatchKit"]),
        // What the share extension links: the confirmation email reader and the drop folder it leaves the
        // email in for the app. Foundation and PDFKit only.
        .library(name: "FlightImportKit", targets: ["FlightImportKit"]),
    ],
    dependencies: [
        .package(path: "../FlightCoreFFI"),
        // Pinned: a new release is taken on purpose, after its changelog is read.
        .package(url: "https://github.com/supabase/supabase-swift", exact: "2.55.5"),
    ],
    targets: [
        .target(
            name: "FlightActivityKit",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "FlightWatchKit",
            dependencies: ["FlightActivityKit"],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "FlightImportKit",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "FlightKit",
            dependencies: [
                "FlightActivityKit",
                "FlightImportKit",
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
                "FlightWatchKit",
                "FlightImportKit",
                // The local-stack smoke test (INTEGRATION=1) signs a user in through the client.
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
