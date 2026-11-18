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

    /// The typed number did not read as a phone number: the line under the field asks for the country code.
    public private(set) var phoneInvalid = false
    /// The device's region (ISO 3166 code, like "US" or "FR"), for numbers typed without their country code.
    public var region: String?

    private let service: any TextAlertsService

    public init(service: any TextAlertsService, region: String? = Locale.current.region?.identifier) {
        self.service = service; self.region = region
    }

    /// The typed number in E.164 ("+14155550100"), or nil while it does not read as one. The field shows it
    /// before the code goes out, so the user sees which number gets the texts.
    public var normalizedPhone: String? { PhoneNumber.e164(phoneDraft, region: region) }

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
        guard !phoneDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let phone = normalizedPhone else { phoneInvalid = true; return }
        phoneInvalid = false
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

    /// The user edits the number: the "not a number" line goes until the next send.
    public func phoneEdited() { phoneInvalid = false }

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

/// Phone numbers in E.164, the form the text line sends to: "+", the country calling code, then the national
/// number without its trunk prefix, 8 to 15 digits in all. A number typed with "+" or an international
/// prefix ("00", "011" in North America) keeps its own country; one typed without takes the device's region.
public enum PhoneNumber {
    /// The E.164 form of `raw`, or nil when it cannot be one (letters, too short or long, an unknown region).
    public static func e164(_ raw: String, region: String?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Only digits and the usual separators; letters (a vanity number, a typo) do not read.
        let allowed = CharacterSet(charactersIn: "+0123456789 -.()/\u{00A0}")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let plus = trimmed.hasPrefix("+")
        // A "+" anywhere but first is a typo.
        guard !trimmed.dropFirst().contains("+") else { return nil }
        var digits = trimmed.filter { $0.isASCII && $0.isNumber }
        let region = region?.uppercased()
        let code = region.flatMap { callingCodes[$0] }

        if !plus {
            if digits.hasPrefix("00") {
                digits.removeFirst(2)
            } else if code == "1", digits.hasPrefix("011") {
                digits.removeFirst(3)
            } else {
                guard let code else { return nil }
                if code == "1" {
                    // North America: ten digits, or eleven with the leading 1.
                    if digits.count == 11, digits.hasPrefix("1") { digits.removeFirst() }
                    guard digits.count == 10 else { return nil }
                } else if digits.hasPrefix("0"), !keepsTrunkZero.contains(region ?? "") {
                    digits.removeFirst()
                }
                digits = code + digits
            }
        }
        guard (8...15).contains(digits.count), let first = digits.first, first != "0" else { return nil }
        return "+" + digits
    }

    /// Countries whose national numbers keep their leading 0 after the country code (Italy, San Marino,
    /// the Vatican).
    static let keepsTrunkZero: Set<String> = ["IT", "SM", "VA"]

    /// Country calling codes by region, for numbers typed without one. Regions not listed need the "+".
    static let callingCodes: [String: String] = [
        "US": "1", "CA": "1", "PR": "1", "GU": "1", "VI": "1", "BS": "1", "BB": "1", "JM": "1", "TT": "1",
        "DO": "1", "MX": "52", "BR": "55", "AR": "54", "CL": "56", "CO": "57", "PE": "51", "VE": "58",
        "UY": "598", "EC": "593", "CR": "506", "PA": "507",
        "GB": "44", "IE": "353", "FR": "33", "BE": "32", "NL": "31", "LU": "352", "DE": "49", "AT": "43",
        "CH": "41", "LI": "423", "IT": "39", "SM": "378", "VA": "39", "ES": "34", "PT": "351", "AD": "376",
        "MC": "377", "DK": "45", "NO": "47", "SE": "46", "FI": "358", "IS": "354", "PL": "48", "CZ": "420",
        "SK": "421", "HU": "36", "RO": "40", "BG": "359", "GR": "30", "CY": "357", "MT": "356", "HR": "385",
        "SI": "386", "RS": "381", "EE": "372", "LV": "371", "LT": "370", "UA": "380", "TR": "90",
        "IL": "972", "AE": "971", "SA": "966", "QA": "974", "EG": "20", "MA": "212", "TN": "216",
        "DZ": "213", "ZA": "27", "NG": "234", "KE": "254", "SN": "221", "CI": "225",
        "IN": "91", "PK": "92", "CN": "86", "HK": "852", "TW": "886", "JP": "81", "KR": "82", "SG": "65",
        "MY": "60", "TH": "66", "VN": "84", "PH": "63", "ID": "62", "AU": "61", "NZ": "64",
        "RE": "262", "GP": "590", "MQ": "596", "GF": "594", "PF": "689", "NC": "687",
    ]
}
