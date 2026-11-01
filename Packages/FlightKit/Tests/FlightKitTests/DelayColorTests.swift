import Testing
@testable import FlightKit

@Suite struct DelayColorTests {
    @Test func delayLevels() {
        #expect(DelayLevel.for(delay: nil, status: .scheduled) == .onTime)
        #expect(DelayLevel.for(delay: .seconds(10 * 60), status: .departed) == .onTime)
        #expect(DelayLevel.for(delay: .seconds(20 * 60), status: .enRoute) == .late)
        #expect(DelayLevel.for(delay: .seconds(50 * 60), status: .scheduled) == .veryLate)
        #expect(DelayLevel.for(delay: .seconds(50 * 60), status: .canceled) == .canceled)
        #expect(DelayLevel.for(delay: nil, status: .diverted) == .diverted)
    }

    @Test func delayBoundaries() {
        #expect(DelayLevel.for(delay: .seconds(14 * 60 + 59), status: .scheduled) == .onTime)
        #expect(DelayLevel.for(delay: .seconds(15 * 60), status: .scheduled) == .late)
        #expect(DelayLevel.for(delay: .seconds(44 * 60 + 59), status: .scheduled) == .late)
        #expect(DelayLevel.for(delay: .seconds(45 * 60), status: .scheduled) == .veryLate)
        #expect(DelayLevel.for(delay: .seconds(-5 * 60), status: .scheduled) == .onTime)
    }

    @Test func labelAndColourAgreeAtTheEdge() {
        // 14m 30s: truncated to 14 for both the text and the level.
        let d = Duration.seconds(14 * 60 + 30)
        #expect(Format.minutes(d) == 14)
        #expect(DelayLevel.for(delay: d, status: .scheduled) == .onTime)
        let d2 = Duration.seconds(44 * 60 + 50)
        #expect(Format.minutes(d2) == 44)
        #expect(DelayLevel.for(delay: d2, status: .scheduled) == .late)
    }

    @Test func errorCopy() {
        #expect(APIError.providerUnavailable.message == "Flight data is temporarily unavailable. Showing the last update.")
        #expect(APIError.notFound.message == "No flight found. Check the number and date.")
        #expect(APIError.rateLimited.message == "Too many searches. Try again in a few minutes.")
        #expect(APIError.planLimit.message == "You can follow up to 3 flights at a time.")
        #expect(APIError.unauthorized.message == "Please sign in again.")
        #expect(APIError.offline.message == "You're offline. Showing the last update.")
    }
}
