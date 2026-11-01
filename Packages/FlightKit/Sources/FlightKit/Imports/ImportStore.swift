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

    /// A row of the source that is not added, and why: it could not be read, or it is a flight the
    /// history already has (`isDuplicate`).
    public struct Skipped: Sendable, Hashable, Identifiable {
        public var label: String
        public var reason: String
        public var isDuplicate = false
        public var id: String { label + reason }

        public init(label: String, reason: String, isDuplicate: Bool = false) {
            self.label = label; self.reason = reason; self.isDuplicate = isDuplicate
        }
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

        /// Every row read, flights or not.
        public var found: Int { candidates.count + skipped.count }
        /// What the history (or the followed list) already has, as rows.
        public var duplicates: [Skipped] {
            left.compactMap { c in if case .duplicate(let why) = c.action { Skipped(label: c.label, reason: why, isDuplicate: true) } else { nil } }
                + skipped.filter(\.isDuplicate)
        }
        /// Rows that are not a flight that can be added, and why.
        public var unreadable: [Skipped] {
            skipped.filter { !$0.isDuplicate }
                + left.compactMap { c in if case .unusable(let why) = c.action { Skipped(label: c.label, reason: why) } else { nil } }
        }
    }

    /// A flight of the import the history did not take, and why; kept so it can be sent again.
    public struct AddFailure: Sendable, Hashable, Identifiable {
        /// Where it came from: "Row 12".
        public var label: String
        public var flight: PastFlight
        public var reason: String
        public var id: PastFlight.ID { flight.id }
    }

    /// What an import did.
    public struct Summary: Sendable, Hashable {
        public var added = 0
        /// Rows of the source not sent: already in the history, unreadable, or unticked.
        public var skipped = 0
        /// Flights the history did not take, with why (stopped ones included).
        public var addFailures: [AddFailure] = []
        /// The traveller stopped the import before every flight was sent.
        public var stopped = false
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
            if !addFailures.isEmpty {
                parts.append(addFailures.count == 1 ? "1 flight couldn't be added." : "\(addFailures.count) flights couldn't be added.")
            }
            if !followed.isEmpty { parts.append("Following \(followed.map(Format.ident).joined(separator: ", ")).") }
            if later > 0 {
                parts.append(later == 1 ? "1 flight will be followed 2 days before it leaves."
                                        : "\(later) flights will be followed 2 days before they leave.")
            }
            if !notFound.isEmpty { parts.append("Couldn't find \(notFound.map(Format.ident).joined(separator: ", ")) to follow.") }
            if !failed.isEmpty { parts.append("Couldn't follow \(failed.map(Format.ident).joined(separator: ", ")) now.") }
            return parts.isEmpty ? "Nothing was added." : parts.joined(separator: " ")
        }

        /// "300 flights added to your Passport", the result screen's headline and the notification's text.
        public var headline: String {
            if added == 0 && followed.isEmpty && later == 0 { return addFailures.isEmpty ? "Nothing new to add" : "No flights were added" }
            if added == 0 { return followed.count + later == 1 ? "1 flight followed" : "\(followed.count + later) flights followed" }
            return added == 1 ? "1 flight added to your Passport" : "\(added.formatted()) flights added to your Passport"
        }
    }

    public enum Phase: Sendable, Hashable {
        case idle
        case reading(Source)
        case review(Review)
        case failed(Source, String)
        /// The ticked flights going into the history, a batch at a time.
        case importing(HistoryImport.Progress)
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
    /// "Import finished: 300 flights added to your Passport", shown over the app when an import ends while
    /// its screen is closed; the presenter clears it.
    public private(set) var toast: String?
    /// Set by the Import screen while it is on screen: the end of an import then shows there, not as a toast.
    public var isScreenVisible = false
    /// Flights per insert request (`HistoryImport.batchSize`; tests make it small).
    @ObservationIgnored public var batchSize = HistoryImport.batchSize
    /// The local notification and background time of a long import; nil sends none (tests, previews).
    @ObservationIgnored public var notifier: (any ImportNotifier)?
    @ObservationIgnored private var work: Task<Void, Never>?

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

    /// Back to the list of sources. Does nothing while an import runs (stop it first).
    public func reset() {
        if case .importing = phase { return }
        phase = .idle
        selected = []
    }

    public func clearToast() { toast = nil }

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

    /// What a file is read against, taken on the main actor so the reading itself can leave it.
    struct Snapshot: Sendable {
        var existing: [PastFlight]
        var followed: [Flight]
        var waiting: [UpcomingFlight]
        var airport: @Sendable (String) -> Airport?
        var reference: ReferenceData
        var now: Date

        var context: FlightImportPlan.Context {
            FlightImportPlan.Context(existing: existing, followed: followed, waiting: waiting, airport: airport,
                                     reference: reference, now: now)
        }
    }

    private var snapshot: Snapshot {
        Snapshot(existing: passport.allFlights, followed: followed(), waiting: queue.items, airport: airport,
                 reference: reference, now: now())
    }

    private var context: FlightImportPlan.Context { snapshot.context }

    private func show(_ review: Review) {
        selected = Set(review.candidates.filter(\.isActionable).map(\.id))
        phase = .review(review)
    }

    // MARK: Sources

    /// The export file of the other tracker, read here (previews and tests; the screen uses `read`).
    public func readFlighty(_ data: Data, name: String? = nil) {
        apply(Self.review(data, as: .flighty, name: name, snapshot: snapshot))
    }

    /// A CSV file of past flights (the app's own export or any with a date, from and to), read here.
    public func readCSV(_ data: Data, name: String? = nil) {
        apply(Self.review(data, as: .csv, name: name, snapshot: snapshot))
    }

    /// A picked export or CSV file, read off the main actor (a file of 2,000 flights takes a moment),
    /// then reviewed. Whichever of the two the traveller picked, the file is read as what it is: the other
    /// tracker's export by its header, else a CSV file.
    public func read(_ data: Data, as source: Source, name: String?) async {
        phase = .reading(source)
        let result = await Self.reviewInBackground(data, as: source, name: name, snapshot: snapshot)
        // Backed out while it was read.
        guard case .reading = phase else { return }
        apply(result)
    }

    /// Shows the screen's "Reading" state while a picked file is opened.
    public func beginReading(_ source: Source) {
        phase = .reading(source)
    }

    private func apply(_ result: Result<Review, Failure>) {
        switch result {
        case .success(let review): show(review)
        case .failure(let f): phase = .failed(f.source, f.message)
        }
    }

    struct Failure: Error, Sendable {
        var source: Source
        var message: String
    }

    @concurrent nonisolated static func reviewInBackground(_ data: Data, as source: Source, name: String?,
                                                           snapshot: Snapshot) async -> Result<Review, Failure> {
        review(data, as: source, name: name, snapshot: snapshot)
    }

    nonisolated static func review(_ data: Data, as source: Source, name: String?, snapshot: Snapshot) -> Result<Review, Failure> {
        let title = name ?? (source == .flighty ? "Exported flights" : "CSV file")
        if FlightyImport.recognizes(data) {
            return flighty(data, title: title, snapshot: snapshot)
        }
        do {
            let preview = try PastFlightImport.preview(data, existing: snapshot.existing, airport: snapshot.airport,
                                                       reference: snapshot.reference, now: snapshot.now)
            return .success(csvReview(preview, title: title, airport: snapshot.airport))
        } catch {
            // Picked as the other tracker's export: say what that export needs.
            if source == .flighty, case .failure(let f) = flighty(data, title: title, snapshot: snapshot) { return .failure(f) }
            return .failure(Failure(source: source, message: error.message))
        }
    }

    nonisolated static func flighty(_ data: Data, title: String, snapshot: Snapshot) -> Result<Review, Failure> {
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
            return .success(Review(source: .flighty, title: title,
                                   candidates: FlightImportPlan.plan(items, context: snapshot.context), skipped: skipped))
        } catch {
            return .failure(Failure(source: .flighty, message: error.message))
        }
    }

    /// A CSV preview as a review: its flights ticked, its duplicates and unreadable rows left out.
    nonisolated static func csvReview(_ p: PastFlightImport.Preview, title: String,
                                      airport: (String) -> Airport?) -> Review {
        let candidates = p.rows.enumerated().map { i, row in
            let f = row.flight
            let zone = airport(f.originIcao)?.timeZone ?? .gmt
            let source = ImportedFlight(airline: f.airline, origin: f.originIcao, destination: f.destinationIcao,
                                        day: LocalDay(f.date, in: zone))
            return ImportCandidate(id: i, label: "Row \(row.row)", source: source, action: .addPast(f), warnings: row.warnings)
        }
        let skipped = p.duplicates.map { Skipped(label: "Row \($0.row)", reason: $0.reason.message, isDuplicate: true) }
            + p.skipped.map { Skipped(label: "Row \($0.row)", reason: $0.reason.message) }
        return Review(source: .csv, title: title, candidates: candidates, skipped: skipped.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending })
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

    /// "Import 12, Follow 2", "Import 1 Flight", "Follow 1 Flight".
    public var commitTitle: String {
        let a = selectedPast.count, f = selectedUpcoming.count
        switch (a, f) {
        case (0, 0): return "Import"
        case (_, 0): return a == 1 ? "Import 1 Flight" : "Import \(a.formatted()) Flights"
        case (0, _): return f == 1 ? "Follow 1 Flight" : "Follow \(f) Flights"
        default: return "Import \(a.formatted()), Follow \(f)"
        }
    }

    // MARK: Commit

    /// Adds the ticked past flights to the history, a batch at a time with the progress on screen, then
    /// follows the ticked upcoming ones (or keeps them to follow once within reach). Returns when it is done
    /// or stopped; the work belongs to the store, so closing the screen does not stop it.
    public func commit() async {
        guard !isCommitting, let review else { return }
        let past = selectedPast, upcoming = selectedUpcoming
        var labels: [PastFlight.ID: String] = [:]
        for c in review.past { if case .addPast(let f) = c.action { labels[f.id] = c.label } }
        await run(past: past, upcoming: upcoming, skipped: review.found - past.count - upcoming.count, labels: labels)
    }

    /// Sends the flights the last import could not add again.
    public func retryFailed() async {
        guard !isCommitting, case .done(let last) = phase, !last.addFailures.isEmpty else { return }
        var labels: [PastFlight.ID: String] = [:]
        for f in last.addFailures { labels[f.flight.id] = f.label }
        await run(past: last.addFailures.map(\.flight), upcoming: [], skipped: last.skipped, labels: labels, before: last)
    }

    /// Stops the import before its next batch; the flights already stored stay.
    public func cancel() {
        work?.cancel()
    }

    static let stoppedReason = "Not sent: the import was stopped"

    private func run(past: [PastFlight], upcoming: [UpcomingFlight], skipped: Int, labels: [PastFlight.ID: String],
                     before: Summary? = nil) async {
        isCommitting = true
        let task = Task { [weak self] () -> Void in
            await self?.perform(past: past, upcoming: upcoming, skipped: skipped, labels: labels, before: before)
        }
        work = task
        await task.value
        work = nil
        isCommitting = false
    }

    private func perform(past: [PastFlight], upcoming: [UpcomingFlight], skipped: Int, labels: [PastFlight.ID: String],
                         before: Summary?) async {
        // A long import may outlast the traveller's patience: they can leave, and hear when it is done.
        let long = past.count > batchSize
        if long { await notifier?.prepare() }
        let token = notifier?.beginBackgroundWork()
        defer { if let token { notifier?.endBackgroundWork(token) } }

        var summary = before ?? Summary()
        summary.skipped = skipped
        summary.addFailures = []
        summary.stopped = false
        summary.addError = nil
        if !past.isEmpty {
            phase = .importing(HistoryImport.Progress(done: 0, total: past.count))
            let outcome = await passport.importFlights(past, batchSize: batchSize) { [weak self] p in
                self?.phase = .importing(p)
            }
            summary.added += outcome.stored.count
            summary.addFailures = outcome.failed.map { AddFailure(label: labels[$0.flight.id] ?? "", flight: $0.flight, reason: $0.reason) }
                + outcome.notSent.map { AddFailure(label: labels[$0.id] ?? "", flight: $0, reason: Self.stoppedReason) }
            summary.stopped = outcome.canceled
        }
        var later: [UpcomingFlight] = []
        for u in upcoming {
            if Task.isCancelled { later.append(u); continue }
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
        summary.later += later.count
        phase = .done(summary)
        await announce(summary)
    }

    /// The end of an import, where the traveller is: nothing more on its own screen, a toast over the app
    /// when they closed it, a notification when they left the app.
    private func announce(_ s: Summary) async {
        var text = s.headline
        if !s.addFailures.isEmpty { text += s.addFailures.count == 1 ? ". 1 couldn't be added" : ". \(s.addFailures.count) couldn't be added" }
        if let notifier, !notifier.isAppActive {
            await notifier.notify(title: "Import finished", body: text + ".")
        } else if !isScreenVisible {
            toast = "Import finished: " + text
        }
    }
}
