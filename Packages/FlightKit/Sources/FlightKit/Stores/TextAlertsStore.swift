import Foundation
import Observation

/// Settings > Notifications > Text Me Too: the number, the code sent to it, the two switches and
/// Forget My Number. Every step waits for the backend (a switch shows the server's answer, not a guess),
/// and a refusal shows the server's words.
@MainActor @Observable
public final class TextAlertsStore {
    public private(set) var status = TextAlertsStatus()
    public private(set) var hasLoaded = false
    public private(set) var isWorking = false
    public private(set) var error: TextAlertsError?
    /// What the last code check said, for the line under the code field.
    public private(set) var codeResult: TextCodeResult?
    public private(set) var triesLeft = 5
    /// What the user types.
    public var phoneDraft = ""
    public var codeDraft = ""

    private let service: any TextAlertsService

    public init(service: any TextAlertsService) { self.service = service }

    /// The step the section shows.
    public enum Step: Equatable {
        /// Texts are off on the server: the section says they are coming.
        case unavailable
        /// No number, or a STOP: the number field.
        case number
        /// A code was sent: the code field.
        case code
        /// Verified: the switches and Forget My Number.
        case verified
    }

    public var step: Step {
        guard status.available else { return .unavailable }
        if status.reachable { return .verified }
        if status.pending { return .code }
        return .number
    }

    public func load() async {
        await run { s throws(TextAlertsError) in try await s.status(flight: nil) }
        hasLoaded = true
    }

    /// Sends the code to the typed number.
    public func sendCode() async {
        let phone = phoneDraft.trimmingCharacters(in: .whitespaces)
        guard !phone.isEmpty else { return }
        codeResult = nil
        codeDraft = ""
        await run { s throws(TextAlertsError) in try await s.start(phone: phone) }
    }

    /// Checks the typed code.
    public func checkCode() async {
        let code = codeDraft.filter(\.isNumber)
        guard code.count == 6 else { codeResult = .wrong; return }
        isWorking = true
        defer { isWorking = false }
        do {
            let (result, s, left) = try await service.check(code: code)
            status = s; codeResult = result; triesLeft = left; error = nil
            if result == .ok { codeDraft = "" }
        } catch {
            self.error = error
        }
    }

    /// Back to the number field (a wrong number, or a code that never came).
    public func changeNumber() {
        status.pending = false
        codeResult = nil
        codeDraft = ""
    }

    public func setEnabled(_ on: Bool) async {
        await run { s throws(TextAlertsError) in try await s.set(enabled: on, inFlight: nil) }
    }

    public func setInFlight(_ on: Bool) async {
        await run { s throws(TextAlertsError) in try await s.set(enabled: nil, inFlight: on) }
    }

    /// Deletes the number from the account.
    public func forget() async {
        await run { s throws(TextAlertsError) in try await s.forget() }
        phoneDraft = ""; codeDraft = ""; codeResult = nil
    }

    /// The words under the code field.
    public var codeMessage: String? {
        switch codeResult {
        case .wrong?: triesLeft > 0 ? "That code is not right. \(triesLeft) \(triesLeft == 1 ? "try" : "tries") left." : nil
        case .expired?: "That code expired. Send a new one."
        case .locked?: "Too many tries. Send a new code."
        case .none?: "Send a code first."
        default: nil
        }
    }

    private func run(_ call: (any TextAlertsService) async throws(TextAlertsError) -> TextAlertsStatus) async {
        isWorking = true
        defer { isWorking = false }
        do {
            status = try await call(service)
            error = nil
        } catch {
            self.error = error
        }
    }

    #if DEBUG
    /// Previews: a state without a load.
    func seed(_ s: TextAlertsStatus, phone: String = "") {
        status = s; phoneDraft = phone; hasLoaded = true
    }
    #endif
}

/// The flight sheet's "Text Me Updates In Flight": that flight's switch over the account's in-flight mode.
/// Shown only once a number is verified. Each sheet makes one and loads it with the flight.
@MainActor @Observable
public final class FlightTextsModel {
    public private(set) var status = TextAlertsStatus()
    public private(set) var error: TextAlertsError?
    private let flight: Flight.ID
    private let service: any TextAlertsService

    public init(flight: Flight.ID, service: any TextAlertsService) {
        self.flight = flight; self.service = service
    }

    /// The switch belongs in the menu: texts are available and the number can be reached.
    public var isShown: Bool { status.available && status.reachable }
    public var isOn: Bool { status.textsInFlight }

    public func load() async {
        do { status = try await service.status(flight: flight); error = nil } catch { self.error = error }
    }

    /// Turns texts on board on or off for this flight. Going back to the account's own setting clears
    /// the flight's switch rather than storing a copy of it.
    public func set(_ on: Bool) async {
        let value: Bool? = on == status.inFlight ? nil : on
        do {
            try await service.setFlight(flight, inFlight: value)
            status.flightInFlight = value
            error = nil
        } catch {
            self.error = error
        }
    }
}
