import SwiftUI
import UniformTypeIdentifiers
import FlightImportKit

extension View {
    /// Shows the Import screen while `home.showImport` is true. The shells attach it where their other
    /// sheets hang; `suspended` holds it back while another sheet (iOS search) is closing.
    public func importSheet(_ home: HomeModel, suspended: Bool = false) -> some View {
        modifier(ImportPresenter(home: home, suspended: suspended))
    }
}

private struct ImportPresenter: ViewModifier {
    var home: HomeModel
    var suspended: Bool

    func body(content: Content) -> some View {
        content
        .overlay(alignment: .top) {
            // An import that ended while its screen was closed.
            if let text = home.imports.toast, !home.showImport {
                ImportToast(text: text) { withAnimation { home.imports.clearToast() } }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: home.imports.toast)
        .sheet(isPresented: Binding(get: { home.showImport && !suspended }, set: { home.showImport = $0 }),
                      onDismiss: { if case .done = home.imports.phase { home.imports.reset() } }) {
            ImportView(store: home.imports, lookup: home.env.lookup) { home.showImport = false }
                #if os(macOS)
                .frame(width: 520, height: 680)
                #else
                .presentationDetents([.large])
                .presentationBackground(Theme.background)
                .presentationCornerRadius(Theme.sheetRadius)
                #endif
        }
    }
}

/// One place to bring flights in: the other tracker's export file, the calendar, a confirmation email
/// and a CSV file. Each is read on this device, reviewed with what was found and why, then the ticked
/// past flights go into the history and the upcoming ones get followed.
public struct ImportView: View {
    @Bindable var store: ImportStore
    var lookup: (String) -> Airport?
    var onClose: () -> Void

    enum Step: Hashable { case sources, email, calendar }

    @State private var step: Step = .sources
    @State private var pasted = ""
    @State private var picker = ImportPicker<Picker>()

    enum Picker: Hashable {
        case flighty, email, csv
        var types: [UTType] {
            switch self {
            case .flighty, .csv: ImportFile.csvTypes
            case .email: HomeModel.emailFileTypes
            }
        }
        var source: ImportStore.Source {
            switch self {
            case .flighty: .flighty
            case .email: .email
            case .csv: .csv
            }
        }
    }

    public init(store: ImportStore, lookup: @escaping (String) -> Airport? = { _ in nil }, onClose: @escaping () -> Void) {
        self.store = store; self.lookup = lookup; self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView { content.scaledPadding(.bottom, 24) }
            footer
        }
        .background(Theme.background)
        .onAppear { store.isScreenVisible = true }
        .onDisappear { store.isScreenVisible = false }
        // The source stays in `picker` while the picker closes: SwiftUI clears `isPresented` before it calls
        // back (see `ImportPicker`).
        .fileImporter(isPresented: $picker.isPresented, allowedContentTypes: picker.kind?.types ?? ImportFile.csvTypes) { result in
            guard let kind = picker.take() else { return }
            switch result {
            case .success(let url): read(url, as: kind)
            case .failure(let error): store.fail(kind.source, "The file couldn't be opened: \(error.localizedDescription)")
            }
        }
        #if os(macOS)
        // A confirmation email dropped on the screen.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            read(url, as: .email)
            return true
        }
        #endif
    }

    /// Opens the picked file off the main actor (inside its security scope, downloading it from iCloud
    /// when needed), then reads it.
    private func read(_ url: URL, as kind: Picker) {
        store.beginReading(kind.source)
        Task {
            switch await ImportFile.read(url) {
            case .failure(let f):
                store.fail(kind.source, f.message)
            case .success(let data):
                if kind == .email { store.readEmailFile(data, name: url.lastPathComponent) }
                else { await store.read(data, as: kind.source, name: url.lastPathComponent) }
            }
        }
    }

    // MARK: Chrome

    private var title: String {
        switch store.phase {
        case .review(let r):
            switch r.source {
            case .flighty: "Import from Flighty"
            case .calendar: "From Your Calendar"
            case .email: "From an Email"
            case .csv: "From a CSV File"
            }
        case .importing: "Importing"
        case .done: "Import Finished"
        default:
            switch step {
            case .sources: "Import Flights"
            case .email: "From an Email"
            case .calendar: "From Your Calendar"
            }
        }
    }

    private var canGoBack: Bool {
        switch store.phase {
        case .review, .failed: true
        case .idle: step != .sources
        case .reading, .importing, .done: false
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if canGoBack {
                RoundButton(systemImage: "chevron.left", label: "Back") { back() }
            }
            Text(title)
                .scaledFont(22, weight: .bold)
                .foregroundStyle(Theme.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            RoundButton(systemImage: "xmark", label: "Close", action: onClose)
        }
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.top, 16)
        .scaledPadding(.bottom, 8)
    }

    private func back() {
        switch store.phase {
        case .review, .failed: store.reset()
        default: step = .sources
        }
    }

    @ViewBuilder private var footer: some View {
        switch store.phase {
        case .review:
            commitBar
        case .importing:
            bar {
                Button("Stop", role: .destructive) { store.cancel() }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .accessibilityHint("Stops after the flights being saved now; the ones saved stay")
            }
        case .done:
            bar {
                Button("Import More") { store.reset(); step = .sources }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                Button("Done") { store.reset(); step = .sources; onClose() }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Theme.accent)
            }
        default:
            EmptyView()
        }
    }

    private func bar(@ViewBuilder _ buttons: () -> some View) -> some View {
        HStack(spacing: 12) {
            Spacer()
            buttons()
        }
        .scaledFont(17, weight: .semibold)
        .controlSize(.large)
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.vertical, 12)
        .background(Theme.background)
    }

    private var commitBar: some View {
        bar {
            Button {
                Task { await store.commit() }
            } label: {
                if store.isCommitting { ProgressView() } else { Text(store.commitTitle) }
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Theme.accent)
            .disabled(store.isCommitting || (store.selectedPast.isEmpty && store.selectedUpcoming.isEmpty))
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .idle:
            switch step {
            case .sources: sources
            case .email: emailEntry
            case .calendar: calendarEntry
            }
        case .reading(let source):
            HStack(spacing: 10) {
                ProgressView()
                Text(source == .calendar ? "Reading your calendar" : "Reading the file")
                    .scaledFont(16).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        case .importing(let progress):
            ImportProgressPanel(progress: progress)
        case .failed(_, let message):
            Text(message)
                .scaledFont(16)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.horizontal, 20)
                .scaledPadding(.top, 20)
        case .review(let review):
            ImportReviewList(review: review, selected: store.selected, lookup: lookup, toggle: store.toggle)
        case .done(let summary):
            ImportResultPanel(summary: summary, lookup: lookup) { Task { await store.retryFailed() } }
        }
    }

    static let privacyLine = "Everything is read on this device. Emails and calendar events are never uploaded; only the flights you add are saved to your account."

    private var sources: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Bring in flights you've taken or booked. Past flights go to your Passport; upcoming ones are followed.")
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.horizontal, 20)
                .scaledPadding(.bottom, 12)
            OptionRow(icon: "tablecells", title: "Import from Flighty",
                      subtitle: "Pick the CSV file you exported from its settings") { picker.open(.flighty) }
            Hairline(leading: 60)
            if store.offersCalendar {
                OptionRow(icon: "calendar", title: "From Your Calendar",
                          subtitle: "Finds flights in your events") { step = .calendar }
                Hairline(leading: 60)
            }
            OptionRow(icon: "envelope", title: "From a Confirmation Email",
                      subtitle: "Share it to Soma Flight, or paste it here") { step = .email }
            Hairline(leading: 60)
            OptionRow(icon: "doc.text", title: "From a CSV File",
                      subtitle: "Any file with a date, from and to") { picker.open(.csv) }
            Text(Self.privacyLine)
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.horizontal, 20)
                .scaledPadding(.top, 16)
            if !store.queue.items.isEmpty { waiting }
        }
    }

    /// Imported flights too far ahead to follow yet.
    private var waiting: some View {
        VStack(alignment: .leading, spacing: 0) {
            CapsHeader("Waiting to follow", trailing: "\(store.queue.items.count)")
                .scaledPadding(.horizontal, 20)
                .scaledPadding(.top, 28)
                .scaledPadding(.bottom, 4)
            Text("Added two days before they leave.")
                .scaledFont(13).foregroundStyle(Theme.secondary)
                .scaledPadding(.horizontal, 20).scaledPadding(.bottom, 6)
            ForEach(store.queue.items) { u in
                Hairline()
                HStack(spacing: 12) {
                    UpcomingLine(flight: u, lookup: lookup)
                    Button { store.queue.remove(u.id) } label: {
                        Image(systemName: "minus.circle").foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop waiting for \(Format.ident(u.ident))")
                }
                .scaledPadding(.horizontal, 20)
                .scaledPadding(.vertical, 10)
            }
        }
    }

    private var emailEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share the airline's confirmation to Soma Flight from Mail, or paste its text below. It is read on this device and never uploaded.")
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $pasted)
                .scaledFont(15)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 220)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.pill))
                .accessibilityLabel("Email text")
            HStack(spacing: 12) {
                Button("Find Flights") { store.readEmail(pasted) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Theme.accent)
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Choose File\u{2026}") { picker.open(.email) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
            .scaledFont(16, weight: .semibold)
            #if os(macOS)
            Text("You can also drop an .eml or PDF file here.").scaledFont(13).foregroundStyle(Theme.secondary)
            #endif
        }
        .scaledPadding(.horizontal, 20)
    }

    private var calendarEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Soma Flight looks for flights in your events: the ones airlines add, and the ones with a flight number or airport codes. The first time, it asks to read your calendar. Events are read on this device; none is changed or uploaded.")
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker("From", selection: $store.calendarStart, in: ...store.calendarEnd, displayedComponents: .date)
            DatePicker("To", selection: $store.calendarEnd, in: store.calendarStart..., displayedComponents: .date)
            Button("Find Flights") { Task { await store.scanCalendar() } }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Theme.accent)
                .scaledFont(16, weight: .semibold)
        }
        .foregroundStyle(Theme.primary)
        .scaledPadding(.horizontal, 20)
    }
}

// MARK: - Review

/// What a source holds: past flights to add and upcoming ones to follow, each with a tick and where it
/// was found, then what will not be added and why.
struct ImportReviewList: View {
    var review: ImportStore.Review
    var selected: Set<ImportCandidate.ID>
    var lookup: (String) -> Airport?
    var toggle: (ImportCandidate.ID) -> Void

    var body: some View {
        // Lazy: a file of 2,000 flights lays out only the rows on screen.
        LazyVStack(alignment: .leading, spacing: 0) {
            ImportReviewSummary(review: review)
            ImportDisclosure(title: "Can't read", items: review.unreadable, startsOpen: review.unreadable.count <= 5) { s in
                ImportReasonRow(label: s.label, reason: s.reason)
            }
            ImportDisclosure(title: "Already in your Passport", items: review.duplicates) { s in
                ImportReasonRow(label: s.label, reason: s.reason)
            }
            section("Past flights", "Added to your Passport", review.past)
            section("Upcoming", "Added now, or two days before they leave", review.upcoming)
        }
    }

    /// "Booking QX4T7B. Found in the email's booking details. 2 to add, 1 to follow, 3 left out."
    static func summary(_ r: ImportStore.Review) -> String {
        var parts = [r.title + "."]
        if let m = r.method { parts.append(m == .structured ? "Found in the email's booking details." : "Found in the email's text.") }
        let left = r.left.count + r.skipped.count
        parts.append("\(r.past.count) to add, \(r.upcoming.count) to follow, \(left) left out.")
        return parts.joined(separator: " ")
    }

    @ViewBuilder private func section(_ title: String, _ note: String, _ rows: [ImportCandidate]) -> some View {
        if !rows.isEmpty {
            CapsHeader(title, trailing: "\(rows.filter { selected.contains($0.id) }.count) of \(rows.count)")
                .scaledPadding(.horizontal, 20)
                .scaledPadding(.top, 22)
            Text(note).scaledFont(13).foregroundStyle(Theme.secondary)
                .scaledPadding(.horizontal, 20).scaledPadding(.bottom, 6)
            ForEach(rows) { c in
                Hairline()
                CandidateRow(candidate: c, ticked: selected.contains(c.id), lookup: lookup) { toggle(c.id) }
            }
        }
    }

    static func reason(_ a: ImportCandidate.Action) -> String {
        switch a {
        case .duplicate(let s), .unusable(let s): s
        case .addPast, .follow: ""
        }
    }
}

/// A tick, the flight, and where it was found.
struct CandidateRow: View {
    var candidate: ImportCandidate
    var ticked: Bool
    var lookup: (String) -> Airport?
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .scaledFont(20)
                    .foregroundStyle(ticked ? Theme.accent : Theme.secondary)
                    .scaledPadding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    switch candidate.action {
                    case .addPast(let f):
                        PastLine(flight: f, lookup: lookup)
                    case .follow(let u):
                        UpcomingLine(flight: u, lookup: lookup)
                    default:
                        Text(Self.headline(candidate.source)).scaledFont(16)
                    }
                    ForEach(candidate.source.evidence, id: \.self) { line in
                        Text(line).scaledFont(13).foregroundStyle(Theme.secondary).lineLimit(2)
                    }
                    ForEach(candidate.warnings, id: \.self) { w in
                        Text(w).scaledFont(13).foregroundStyle(Theme.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .scaledPadding(.horizontal, 20)
            .scaledPadding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(ticked ? [.isSelected, .isButton] : .isButton)
    }

    /// "AF 84 CDG → SFO, 2027-03-14".
    static func headline(_ f: ImportedFlight) -> String {
        var parts: [String] = []
        if let ident = f.ident { parts.append(Format.ident(ident)) }
        if let o = f.origin, let d = f.destination { parts.append("\(o) \u{2192} \(d)") }
        parts.append(f.day.description)
        return parts.joined(separator: " ")
    }
}

/// "AF 84  CDG → SFO", "Paris to San Francisco", the day.
private struct PastLine: View {
    var flight: PastFlight
    var lookup: (String) -> Airport?

    var body: some View {
        let o = lookup(flight.originIcao), d = lookup(flight.destinationIcao)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                if !flight.ident.isEmpty {
                    Text(Format.ident(flight.ident)).scaledFont(15, weight: .medium).foregroundStyle(Theme.secondary)
                }
                Text("\(o?.iata ?? flight.originIcao) \u{2192} \(d?.iata ?? flight.destinationIcao)")
                    .scaledFont(15).foregroundStyle(Theme.secondary.opacity(0.8))
                Spacer(minLength: 6)
                Text(ScreenFormat.day(flight.date, o?.timeZone ?? .gmt))
                    .scaledFont(15, weight: .medium).monospacedDigit().foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 8) {
                RouteText(from: o?.city ?? flight.originIcao, to: d?.city ?? flight.destinationIcao).lineLimit(1)
                if flight.status != .completed {
                    Text(flight.status == .canceled ? "CANCELED" : "DIVERTED")
                        .scaledFont(11, weight: .bold).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

/// "AF 84  CDG → SFO", the day and whether it is followed now or later.
struct UpcomingLine: View {
    var flight: UpcomingFlight
    var lookup: (String) -> Airport?

    var body: some View {
        let o = flight.origin.flatMap(lookup), d = flight.destination.flatMap(lookup)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Text(Format.ident(flight.ident)).scaledFont(15, weight: .medium).foregroundStyle(Theme.secondary)
                if let from = flight.origin, let to = flight.destination {
                    Text("\(o?.iata ?? from) \u{2192} \(d?.iata ?? to)").scaledFont(15).foregroundStyle(Theme.secondary.opacity(0.8))
                }
                Spacer(minLength: 6)
                Text(Self.day(flight.day)).scaledFont(15, weight: .medium).monospacedDigit().foregroundStyle(Theme.secondary)
            }
            if let from = flight.origin, let to = flight.destination {
                RouteText(from: o?.city ?? from, to: d?.city ?? to).lineLimit(1)
            }
        }
    }

    /// "14 Mar 2027".
    static func day(_ d: LocalDay) -> String {
        guard let date = PastFlightRules.noon(year: d.year, month: d.month, day: d.day, in: .gmt) else { return d.description }
        return ScreenFormat.day(date, .gmt)
    }
}

#if DEBUG
#Preview("Sources") {
    @Previewable @State var store = ImportPreview.store()
    ImportView(store: store, lookup: PreviewData.airport) {}.preferredColorScheme(.dark)
}

#Preview("Email review") {
    @Previewable @State var store: ImportStore = {
        let s = ImportPreview.store()
        s.readEmail(ImportPreview.email)
        return s
    }()
    ImportView(store: store, lookup: PreviewData.airport) {}.preferredColorScheme(.dark)
}

#Preview("Flighty review") {
    @Previewable @State var store: ImportStore = {
        let s = ImportPreview.store()
        s.readFlighty(Data(ImportPreview.flighty.utf8), name: "flights.csv")
        return s
    }()
    ImportView(store: store, lookup: PreviewData.airport) {}.preferredColorScheme(.light)
}

/// Fakes for the Import previews.
@MainActor enum ImportPreview {
    static func store() -> ImportStore {
        let calendar = FakeCalendarStore(access: .full)
        calendar.external = [CalendarEventSnapshot(id: "1", title: "Flight to Paris (AF 84)", location: "San Francisco SFO",
                                                   start: PreviewData.now.addingTimeInterval(-40 * 86_400),
                                                   end: PreviewData.now.addingTimeInterval(-40 * 86_400 + 39_600))]
        return ImportStore(passport: PassportStore(history: FakeHistoryService()), flights: FakeFlightService(now: PreviewData.now),
                           queue: FollowLaterQueue(owner: nil, defaults: nil),
                           calendar: CalendarSync(store: calendar, lookup: PreviewData.airport, defaults: nil),
                           airport: PreviewData.airport, now: { PreviewData.now })
    }

    static let email = """
    Your booking reference: XJ7K2P
    Sat 14 Mar 2026
    BA 286   San Francisco (SFO) 19:40 -> London Heathrow (LHR) 13:55
    Seat 32K
    Sun 22 Nov 2026
    BA 287   London Heathrow (LHR) 11:35 -> San Francisco (SFO) 14:30
    """

    static let flighty = """
    Date,Airline,Flight,From,To,Canceled,Diverted To,Gate Departure (Scheduled),Aircraft Type Name,Tail Number,Seat,Seat Type,Cabin Class,Flight Reason,Notes
    2025-08-16,AFR,84,CDG,SFO,false,,2025-08-16T10:15,Boeing 777-300ER,F-GSQA,12A,WINDOW,BUSINESS,LEISURE,
    2025-08-30,UAL,990,SFO,CDG,true,,2025-08-30T15:35,,,,,ECONOMY,BUSINESS,
    2025-09-02,,,,,false,,,,,,,,,
    """
}
#endif
