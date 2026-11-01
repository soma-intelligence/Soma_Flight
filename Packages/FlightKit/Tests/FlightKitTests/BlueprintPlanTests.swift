import Testing
@testable import FlightKit

/// The plan drawing's families and geometry, and the ranking under the most flown type.
@MainActor
struct BlueprintPlanTests {
    @Test func familiesMapToPlans() {
        #expect(PlanFamily(.a320) == .narrow)
        #expect(PlanFamily(.b737max) == .narrow)
        #expect(PlanFamily(.b787) == .wideTwin)
        #expect(PlanFamily(.a350) == .wideTwin)
        #expect(PlanFamily(.a380) == .wideQuad)
        #expect(PlanFamily(.ejet) == .regional)
        #expect(PlanFamily(.crj) == .rearJet)
        #expect(PlanFamily(.atr) == .turboprop)
        #expect(PlanFamily(nil) == .narrow)
    }

    /// Each plan is closed and plausible: the nose and barrel widths, the wing outboard of the fuselage and
    /// swept back, the cabin inside the barrel, the nacelles reaching under the wing (or the rear fuselage).
    @Test func plansAreConsistent() {
        for family in PlanFamily.allCases {
            let g = family.plan
            #expect(g.halfWidth(0) == 0)
            #expect(abs(g.halfWidth(g.length / 2) - g.width / 2) < 1e-9)
            #expect(g.halfWidth(g.length) <= g.tailWidth / 2 + 1e-9)
            #expect(g.wing.span > g.width * 4)
            #expect(g.wing.trailingEdge(g.wing.span / 2) > g.wing.leadingEdge(g.wing.span / 2))
            #expect(g.cabin.lowerBound > g.noseLength * 0.5 && g.cabin.upperBound < g.length - g.tailLength / 2)
            for e in g.engines where !e.rear && !g.highWing {
                #expect(e.x + e.length > g.wing.leadingEdge(e.y), "\(family) nacelle stops ahead of the wing")
            }
            #expect(abs(Double(g.bounds.width) - g.length) < 1e-6)
        }
    }

    @Test func runnersUpFollowTheMostFlown() async {
        let store = PassportStore(history: FakeHistoryService())
        await store.load()
        let ranks = store.runnersUp()
        #expect(ranks.count <= 4)
        #expect(!ranks.contains { $0.tally.icaoType == store.aircraft.mostFlown?.icaoType })
        #expect(ranks.map(\.tally.flights) == ranks.map(\.tally.flights).sorted(by: >))
    }
}
