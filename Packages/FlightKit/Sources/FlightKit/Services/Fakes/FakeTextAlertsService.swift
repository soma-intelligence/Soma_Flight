import Foundation

/// Texts in memory for `-useFakes`, previews and tests: available, nothing sent. The code is always
/// `FakeTextAlertsService.code`; five wrong tries lock it like the server does.
public actor FakeTextAlertsService: TextAlertsService {
    public static let code = "123456"
    public private(set) var row: TextAlertsStatus
    public private(set) var flights: [Flight.ID: Bool] = [:]
    private var tries = 0
    public var nextError: TextAlertsError?

    public init(_ row: TextAlertsStatus = TextAlertsStatus(available: true)) { self.row = row }

    public func setNextError(_ e: TextAlertsError?) { nextError = e }

    private func fail() throws(TextAlertsError) {
        if let e = nextError { nextError = nil; throw e }
    }

    public func status(flight: Flight.ID?) async throws(TextAlertsError) -> TextAlertsStatus {
        try fail()
        var s = row
        s.flightInFlight = flight.flatMap { flights[$0] }
        return s
    }

    public func start(phone: String) async throws(TextAlertsError) -> TextAlertsStatus {
        try fail()
        let digits = phone.filter(\.isNumber)
        guard digits.count >= 10 else { throw .refused("Enter a number with its country code") }
        row.phone = phone.hasPrefix("+") ? "+\(digits)" : "+1\(digits.suffix(10))"
        row.pending = true; row.verified = false; row.enabled = false; row.inFlight = false
        tries = 0
        return row
    }

    public func check(code: String) async throws(TextAlertsError) -> (TextCodeResult, TextAlertsStatus, triesLeft: Int) {
        try fail()
        guard row.pending else { return (.none, row, 0) }
        guard tries < 5 else { return (.locked, row, 0) }
        guard code == Self.code else { tries += 1; return (tries >= 5 ? .locked : .wrong, row, 5 - tries) }
        row.pending = false; row.verified = true; row.enabled = true; row.optedOut = false
        return (.ok, row, 5)
    }

    public func set(enabled: Bool?, inFlight: Bool?) async throws(TextAlertsError) -> TextAlertsStatus {
        try fail()
        if enabled == true || inFlight == true, !row.reachable { throw .refused("Verify your number first") }
        if let enabled { row.enabled = enabled }
        if let inFlight { row.inFlight = inFlight }
        return row
    }

    public func setFlight(_ flight: Flight.ID, inFlight: Bool?) async throws(TextAlertsError) {
        try fail()
        if inFlight == true, !row.reachable { throw .refused("Verify your number first") }
        flights[flight] = inFlight
    }

    public func forget() async throws(TextAlertsError) -> TextAlertsStatus {
        try fail()
        row = TextAlertsStatus(available: row.available)
        flights = [:]
        return row
    }
}
