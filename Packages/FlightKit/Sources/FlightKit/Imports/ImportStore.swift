import Foundation
import Observation
import FlightImportKit

/// The Import screen's state: read a source (the export file, the calendar, a confirmation email),
/// review what it holds, then add the past flights to the history and follow the upcoming ones. Every
/// source is read on this device; only the flights the traveller ticks are sent, the way a flight added
/// by hand is.
@MainActor @Observable
public final class ImportStore {
    public enum Source: String, Sendable, Hashable, Identifiable, CaseIterable {
        case flighty, calendar, email, csv
        public var id: String { rawValue }
    }

    /// A row of the source that is not a flight, and why.
    public struct Skipped: Sendable, Hashable, Identifiable {
        public var label: String
        public var reason: String
        public var id: String { label + reason }
    }

    /// What a source holds, before anything is added.
    public struct Review: Sendable, Hashable {
        public var source: Source
        /// "Booking QX4T7B is confirmed", "Calendar, 14 Oct 2024 to 31 Oct 2027", "flighty.csv".
        public var title: String
        public var candidates: [ImportCandidate]
        public var skipped: [Skipped]
        /// For an email: found in its booking markup or in its text.
        public var method: EmailFlightReader.Method?

        public var past: [ImportCandidate] { candidates.filter { if case .addPast = $0.action { true } else { false } } }
        public var upcoming: [ImportCandidate] { candidates.filter { if case .follow = $0.action { true } else { false } } }
        public var left: [ImportCandidate] { candidates.filter { !$0.isActionable } }
    }

    /// What an import did.
    public struct Summary: Sendable, Hashable {
        public var added = 0
        public var followed: [String] = []
        /// Waiting on this device until they come within two days.
        public var later = 0
        public var notFound: [String] = []
        public var failed: [String] = []
        /// Why the history refused the flights, when it did.
        public var addError: String?

        /// "Added 12 flights to your history. Following AF 84. 2 flights will be followed 2 days before they leave."
        public var message: String {
            var parts: [String] = []
            if let addError { parts.append(addError) }
            if added > 0 { parts.append(added == 1 ? "Added 1 flight to your history." : "Added \(added) flights to your history.") }
            if !followed.isEmpty { parts.append("Following \(followed.map(Format.ident).joined(separator: ", ")).") }
            if later > 0 {
                parts.append(later == 1 ? "1 flight will be followed 2 days before it leaves."
                                        : "\(later) flights will be followed 2 days before they leave.")
            }
            if !notFound.isEmpty { parts.append("Couldn't find \(notFound.map(Format.ident).joined(separator: ", ")) to follow.") }
            if !failed.isEmpty { parts.append("Couldn't follow \(failed.map(Format.ident).joined(separator: ", ")) now.") }
            return parts.isEmpty ? "Nothing was added." : parts.joined(separator: " ")
        }
    }

    public enum Phase: Sendable, Hashable {
        case idle
        case reading(Source)
        case review(Review)
        case failed(Source, String)
        case done(Summary)
    }

    public private(set) var phase: Phase = .idle
    /// The candidates ticked for adding (all that can be added, at first).
    public var selected: Set<ImportCandidate.ID> = []
    /// The calendar range scanned: two years back, a year ahead by default.
    public var calendarStart: Date
    public var calendarEnd: Date
    /// True while the ticked flights are being added and followed.
    public private(set) var isCommitting = false

    @ObservationIgnored let passport: PassportStore
    @ObservationIgnored private let flights: any FlightService
    @ObservationIgnored let queue: FollowLaterQueue
    @ObservationIgnored private let calendar: CalendarSync?
    @ObservationIgnored private let followed: () -> [Flight]
    @ObservationIgnored private let airport: @Sendable (String) -> Airport?
    @ObservationIgnored private let reference: ReferenceData
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let onFollowed: (Flight) async -> Void

    /// - Parameters:
    ///   - calendar: the calendar sync, whose access the calendar import reuses; nil hides that source.
    ///   - followed: the flights followed now, so an import does not follow one twice.
    ///   - onFollowed: runs after the imported flights are followed (reloads My Flights).
    public init(passport: PassportStore, flights: any FlightService, queue: FollowLaterQueue, calendar: CalendarSync?,
                followed: @escaping () -> [Flight] = { [] }, airport: @escaping @Sendable (String) -> Airport?,
                reference: ReferenceData = .bundled(), now: @escaping () -> Date = { .now },
                onFollowed: @escaping (Flight) async -> Void = { _ in }) {
        self.passport = passport; self.flights = flights; self.queue = queue; self.calendar = calendar
        self.followed = followed; self.airport = airport; self.reference = reference; self.now = now
        self.onFollowed = onFollowed
        let t = now()
        calendarStart = Calendar(identifier: .gregorian).date(byAdding: .year, value: -2, to: t) ?? t
        calendarEnd = Calendar(identifier: .gregorian).date(byAdding: .year, value: 1, to: t) ?? t
    }

    public var offersCalendar: Bool { calendar != nil }

    /// Back to the list of sources.
    public func reset() {
        phase = .idle
        selected = []
    }

    /// Shows why a source could not be read (a file the screen could not open).
    public func fail(_ source: Source, _ message: String) {
        phase = .failed(source, message)
    }

    /// An airport the list knows, or three capitals that are not a booking word (the list on the device
    /// is short; the server knows every airport).
    var isAirport: (String) -> Bool {
        let airport = airport
        return { airport($0) != nil || EmailFlightReader.plausibleAirport($0) }
    }

    private var context: FlightImportPlan.Context {
        FlightImportPlan.Context(existing: passport.allFlights, followed: followed(), waiting: queue.items,
                                 airport: airport, reference: reference, now: now())
    }

    private func show(_ review: Review) {
        selected = Set(review.candidates.filter(\.isActionable).map(\.id))
        phase = .review(review)
    }

    // MARK: Sources

    /// The export file of the other tracker.
    public func readFlighty(_ data: Data, name: String? = nil) {
        do {
            let rows = try FlightyImport.read(data)
            var items: [(label: String, flight: ImportedFlight)] = []
            var skipped: [Skipped] = []
            for row in rows {
                switch row.flight {
                case .success(let f): items.append(("Row \(row.row)", f))
                case .failure(let why): skipped.append(Skipped(label: "Row \(row.row)", reason: why.message))
                }
            }
            show(Review(source: .flighty, title: name ?? "Exported flights",
                        candidates: FlightImportPlan.plan(items, context: context), skipped: skipped))
        } catch {
            phase = .failed(.flighty, error.message)
        }
    }

    /// A confirmation email: its raw source, its pasted text or a PDF's text.
    public func readEmail(_ text: String, name: String? = nil) {
        let message = EmailMessage.parse(text)
        let result = EmailFlightReader.read(message, pdfText: message.pdfs.compactMap(PDFText.text), now: now(),
                                            isAirport: isAirport)
        guard !result.flights.isEmpty else {
            phase = .failed(.email, "No flights found in this email. Try the airline's confirmation or e-ticket, or its PDF itinerary.")
            return
        }
        let label = message.subject ?? name ?? "Email"
        let items = result.flights.map { (label: "\(label)", flight: $0) }
        show(Review(source: .email, title: label, candidates: FlightImportPlan.plan(items, context: context),
                    skipped: [], method: result.method))
    }

    /// A shared or picked file: an `.eml`, a text file or a PDF.
    public func readEmailFile(_ data: Data, name: String?) {
        guard let text = SharedEmailFile.text(data: data, name: name) else {
            phase = .failed(.email, "This file has no text Soma Flight can read. Share the email itself, or paste its text.")
            return
        }
        readEmail(text, name: name)
    }

    /// The calendar between `calendarStart` and `calendarEnd`. Asks for full calendar access the first
    /// time (it is the traveller starting this import that asks).
    public func scanCalendar() async {
        guard let calendar else { return }
        phase = .reading(.calendar)
        switch await calendar.readEvents(from: calendarStart, to: calendarEnd) {
        case .failure(let refusal):
            phase = .failed(.calendar, refusal.message)
        case .success(let events):
            let matches = CalendarFlightMatcher.matches(events, ownCalendarId: calendar.appCalendarId,
                                                        isAirport: isAirport, airport: airport)
            guard !matches.isEmpty else {
                phase = .failed(.calendar, "No flights found in your calendar between these dates.")
                return
            }
            let items = matches.map { (label: $0.event.title, flight: $0.flight) }
            let review = Review(source: .calendar, title: Self.range(calendarStart, calendarEnd),
                                candidates: FlightImportPlan.plan(items, context: context), skipped: [])
            // A likely match (no airports, or no number) waits for a tick.
            let likely = Set(zip(review.candidates, matches).filter { $0.1.strength == .likely }.map(\.0.id))
            show(review)
            selected.subtract(likely)
        }
    }

    static func range(_ a: Date, _ b: Date) -> String {
        let f = Date.FormatStyle(date: .abbreviated, time: .omitted)
        return "\(a.formatted(f)) to \(b.formatted(f))"
    }

    // MARK: Ticks

    public func toggle(_ id: ImportCandidate.ID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    public var review: Review? {
        if case .review(let r) = phase { r } else { nil }
    }

    public var selectedPast: [PastFlight] {
        review?.past.filter { selected.contains($0.id) }.compactMap {
            if case .addPast(let f) = $0.action { f } else { nil }
        } ?? []
    }

    public var selectedUpcoming: [UpcomingFlight] {
        review?.upcoming.filter { selected.contains($0.id) }.compactMap {
            if case .follow(let u) = $0.action { u } else { nil }
        } ?? []
    }

    /// "Add 12, Follow 2", "Add 1 Flight", "Follow 1 Flight".
    public var commitTitle: String {
        let a = selectedPast.count, f = selectedUpcoming.count
        switch (a, f) {
        case (0, 0): return "Add"
        case (_, 0): return a == 1 ? "Add 1 Flight" : "Add \(a) Flights"
        case (0, _): return f == 1 ? "Follow 1 Flight" : "Follow \(f) Flights"
        default: return "Add \(a), Follow \(f)"
        }
    }

    // MARK: Commit

    /// Adds the ticked past flights to the history and follows the ticked upcoming ones (or keeps them to
    /// follow once within reach).
    public func commit() async {
        guard !isCommitting else { return }
        isCommitting = true
        defer { isCommitting = false }
        var summary = Summary()
        let past = selectedPast, upcoming = selectedUpcoming
        if !past.isEmpty {
            if let n = await passport.importFlights(past) {
                summary.added = n
            } else {
                summary.addError = (passport.writeError?.message ?? "The flights could not be added.")
                    + " Flights already added stay; importing again adds only the rest."
            }
        }
        var later: [UpcomingFlight] = []
        for u in upcoming {
            switch await ImportFollower.follow(u, flights: flights, reference: reference, airport: airport, now: now()) {
            case .followed(let flight):
                summary.followed.append(flight.ident)
                await onFollowed(flight)
            case .later:
                later.append(u)
            case .failed(let e) where e == .offline || e == .providerUnavailable:
                // Tried again with the waiting ones.
                later.append(u)
            case .failed:
                summary.failed.append(u.ident)
            case .notFound, .gone:
                summary.notFound.append(u.ident)
            }
        }
        queue.add(later)
        summary.later = later.count
        phase = .done(summary)
    }
}
