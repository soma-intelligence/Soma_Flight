import CoreGraphics
import CoreLocation
import Foundation
import PDFKit
import Testing
@testable import FlightKit

/// Plan 23: the route poster, a vector PDF of every route flown, made on the device.
@Suite struct RoutePosterTests {
    static let t0 = Date(timeIntervalSince1970: 1_741_593_600) // 2025-03-10

    static func leg(_ from: String, _ to: String, day: Double = 0, status: PastFlightStatus = .completed) -> PastFlight {
        PastFlight(date: t0.addingTimeInterval(day * 86_400), ident: "AF84", originIcao: from, destinationIcao: to,
                   distanceKm: 1_000, status: status, originTz: "UTC")
    }

    static let lookup = PassportStore.bundledAirports

    @Test func pageSizePerFormat() throws {
        let poster = try #require(RoutePoster.make([Self.leg("KSFO", "LFPG"), Self.leg("LFPG", "KSFO", day: 9)],
                                                   year: nil, name: nil, unit: .km, airport: Self.lookup))
        let expected: [RoutePoster.Format: (CGFloat, CGFloat)] = [
            .a3: (1_190.55, 841.89), .a2: (1_683.78, 1_190.55), .us18x24: (1_728, 1_296),
        ]
        for format in RoutePoster.Format.allCases {
            for style in RoutePoster.Style.allCases {
                let doc = try #require(PDFDocument(data: poster.pdf(format, style: style)), "\(format) \(style)")
                #expect(doc.pageCount == 1)
                let box = try #require(doc.page(at: 0)).bounds(for: .mediaBox)
                let want = try #require(expected[format])
                #expect(abs(box.width - want.0) < 0.1, "\(format)")
                #expect(abs(box.height - want.1) < 0.1, "\(format)")
            }
        }
    }

    @Test func posterIsVectorWithItsWords() throws {
        let poster = try #require(RoutePoster.make([Self.leg("KSFO", "LFPG")], year: 2025, name: "Ada Lovelace",
                                                   unit: .km, airport: Self.lookup))
        let doc = try #require(PDFDocument(data: poster.pdf(.a3, style: .paper)))
        let text = doc.string ?? ""
        #expect(text.contains("Ada Lovelace"))
        #expect(text.contains("2025"))
        #expect(text.contains("1 flight"))
        // A vector page carries no image XObject.
        #expect(!String(decoding: poster.pdf(.a3, style: .night), as: UTF8.self).contains("/Subtype /Image"))
    }

    @Test func titleAndCounts() throws {
        let flights = [Self.leg("KSFO", "LFPG"), Self.leg("LFPG", "KSFO", day: 400), Self.leg("KSFO", "KJFK", day: 3),
                       Self.leg("KSFO", "RJTT", day: 5, status: .canceled)]
        let poster = try #require(RoutePoster.make(flights, year: nil, name: "  ", unit: .km, airport: Self.lookup))
        #expect(poster.title == "My flights")
        #expect(poster.period == "2025 to 2026")
        #expect(poster.flights == 3)
        #expect(poster.arcs.count == 2)
        #expect(poster.arcs.last?.flights == 2)
        #expect(poster.airports.count == 3)
        #expect(poster.counts.contains("3 flights"))
        #expect(poster.counts.contains("2 countries"))
        #expect(!poster.counts.contains("\u{2014}"))
    }

    @Test func noFlightsNoPoster() {
        #expect(!RoutePoster.isAvailable([], airport: Self.lookup))
        #expect(!RoutePoster.isAvailable([Self.leg("KSFO", "LFPG", status: .canceled)], airport: Self.lookup))
        #expect(RoutePoster.isAvailable([Self.leg("KSFO", "LFPG")], airport: Self.lookup))
        #expect(RoutePoster.make([], year: nil, name: nil, unit: .km, airport: Self.lookup) == nil)
        #expect(RoutePoster.make([Self.leg("KSFO", "LFPG")], year: 2019, name: nil, unit: .km, airport: Self.lookup) == nil)
        #expect(RoutePoster.make([Self.leg("KSFO", "LFPG", status: .canceled)], year: nil, name: nil, unit: .km,
                                 airport: Self.lookup) == nil)
    }

    @Test func antimeridianArcsSplit() throws {
        let nrt = CLLocationCoordinate2D(latitude: 35.76, longitude: 140.39)
        let sfo = CLLocationCoordinate2D(latitude: 37.62, longitude: -122.38)
        let runs = RouteMap.runs(nrt, sfo)
        #expect(runs.count == 2)
        #expect(abs(abs(try #require(runs.first?.last).longitude) - 180) < 1e-9)
        #expect(abs(abs(try #require(runs.last?.first).longitude) - 180) < 1e-9)
        // No line jumps across the page.
        let rect = CGRect(x: 0, y: 0, width: 1_000, height: 500)
        for run in runs {
            let points = run.map { RouteMap.point(lon: $0.longitude, lat: $0.latitude, in: rect) }
            for (a, b) in zip(points, points.dropFirst()) { #expect(abs(a.x - b.x) < rect.width / 2) }
        }
        // A route that stays on one side is one run.
        #expect(RouteMap.runs(sfo, CLLocationCoordinate2D(latitude: 49.0, longitude: 2.55)).count == 1)
    }

    @Test func thousandFlightsRenderQuickly() throws {
        let codes = Array(Set(["KSFO", "LFPG", "KJFK", "EGLL", "RJTT", "YSSY", "OMDB", "WSSS", "SBGR", "FAOR", "CYYZ",
                               "EDDF", "LEMD", "VHHH", "ZBAA", "KLAX", "KORD", "PHNL", "NZAA", "SCEL", "MMMX",
                               "UUEE", "VIDP", "RKSI", "EHAM", "LIRF", "KSEA", "KMIA", "LTFM", "HECA"]))
        var flights: [PastFlight] = []
        for i in 0..<1_000 {
            let a = codes[i % codes.count], b = codes[(i * 7 + 3) % codes.count]
            flights.append(Self.leg(a, a == b ? "KDEN" : b, day: Double(i)))
        }
        let start = Date()
        let poster = try #require(RoutePoster.make(flights, year: nil, name: nil, unit: .km, airport: Self.lookup))
        let data = poster.pdf(.a2, style: .blueprint)
        let elapsed = Date().timeIntervalSince(start)
        #expect(poster.flights == 1_000)
        #expect(data.count > 10_000)
        #expect(elapsed < 3, "took \(elapsed) s")
    }

    @Test func previewBitmap() throws {
        let poster = try #require(RoutePoster.make([Self.leg("KSFO", "LFPG")], year: nil, name: nil, unit: .km,
                                                   airport: Self.lookup))
        let image = try #require(poster.preview(.a3, style: .night, width: 600))
        #expect(image.width == 600)
        #expect(image.height == 424)
    }
}
