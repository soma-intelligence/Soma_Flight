import Testing
@testable import FlightKit

/// The sign-in globe turns eastward and wraps at the antimeridian.
@Suite struct SpinningGlobeTests {
    @Test func turnsAndWraps() {
        #expect(abs(SpinningGlobe.advanced(-40, by: 10) - (-40 + SpinningGlobe.speed * 10)) < 1e-9)
        let wrapped = SpinningGlobe.advanced(179.9, by: 1)
        #expect(wrapped < -179 && wrapped > -180)
    }
}
