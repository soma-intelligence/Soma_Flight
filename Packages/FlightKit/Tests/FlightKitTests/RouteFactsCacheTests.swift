import Foundation
import Testing
@testable import FlightKit

@MainActor struct RouteFactsCacheTests {
    private func key(seat: String? = nil) -> RouteFactsCache.Key {
        .init(flight: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, status: .scheduled, out: nil, in: nil,
              origin: "LFPG", destination: "EGLL", aircraft: "A320", seat: seat, clock: .h24)
    }

    @Test func theRouteIsWorkedOutOncePerKey() {
        let cache = RouteFactsCache()
        for _ in 0..<5 { _ = cache.facts(for: key()) { RouteFacts() } }
        #expect(cache.computations == 1)
        _ = cache.facts(for: key(seat: "6A")) { RouteFacts() }
        #expect(cache.computations == 2)
    }
}
