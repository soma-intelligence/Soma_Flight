import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

// MARK: Status tracker

/// Adds or edits a status programme: a name, the airlines that count, the period and up to two goals.
/// The distance goal is typed in the app's unit.
struct StatusProgramEditor: View {
    var store: StatusPrograms
    var program: StatusProgram?
    var unit: DistanceUnit
    @Environment(\.dismiss) private var dismiss

    enum Scope: Hashable { case alliance, airlines }

    @State private var name = ""
    @State private var scope: Scope = .alliance
    @State private var alliance: Alliance = .starAlliance
    @State private var codes: [String] = []
    @State private var period: StatusProgram.Period = .calendarYear
    @State private var segments = ""
    @State private var distance = ""

    init(store: StatusPrograms, program: StatusProgram? = nil, unit: DistanceUnit) {
        self.store = store; self.program = program; self.unit = unit
        guard let p = program else { return }
        _name = State(initialValue: p.name)
        _period = State(initialValue: p.period)
        _segments = State(initialValue: p.segmentGoal.map(String.init) ?? "")
        _distance = State(initialValue: p.distanceGoal.map {
            String(StatusTracker.distance(StatusTracker.km($0, from: p.distanceUnit), in: unit))
        } ?? "")
        switch p.airlines {
        case .alliance(let a): _alliance = State(initialValue: a)
        case .airlines(let c): _scope = State(initialValue: .airlines); _codes = State(initialValue: c)
        }
    }

    private var draft: StatusProgram {
        StatusProgram(id: program?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                      airlines: scope == .alliance ? .alliance(alliance) : .airlines(codes), period: period,
                      segmentGoal: Int(segments.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil },
                      distanceGoal: Int(distance.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil },
                      distanceUnit: unit)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, like Gold or Executive Club Silver", text: $name)
                } footer: {
                    Text("Your own goal, typed in. Soma Flight never signs in to an airline.")
                }
                Section("Flights that count") {
                    Picker("Count", selection: $scope) {
                        Text("An alliance").tag(Scope.alliance)
                        Text("Airlines I pick").tag(Scope.airlines)
                    }
                    if scope == .alliance {
                        Picker("Alliance", selection: $alliance) {
                            ForEach(Alliance.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                        }
                    } else {
                        NavigationLink {
                            StatusAirlinePicker(codes: $codes)
                        } label: {
                            LabeledContent("Airlines") {
                                Text(verbatim: codes.isEmpty ? String(localized: "None", bundle: .main) : "\(codes.count)")
                            }
                        }
                    }
                    Picker("Period", selection: $period) {
                        ForEach(StatusProgram.Period.allCases, id: \.self) { Text(ui: $0.title).tag($0) }
                    }
                }
                Section {
                    goalField("Segments", text: $segments)
                    goalField(unit == .km ? "Distance in km" : "Distance in miles", text: $distance)
                } header: {
                    Text("Goals")
                } footer: {
                    Text("Fill in one goal or both. Canceled flights never count.")
                }
                if let program {
                    Section {
                        Button("Delete Status Goal", role: .destructive) {
                            store.remove(program.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(Text(program == nil ? "New Status Goal" : "Status Goal"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.save(draft)
                        dismiss()
                    }
                    .disabled(!draft.isValid)
                }
            }
        }
    }

    private func goalField(_ title: String, text: Binding<String>) -> some View {
        TextField(String(localized: String.LocalizationValue(title), bundle: .main), text: text)
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
    }
}

/// Every airline of the bundled list, searchable, with a check on the ones picked.
struct StatusAirlinePicker: View {
    @Binding var codes: [String]
    @State private var query = ""
    private static let all = ReferenceData.bundled().airlines.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }

    private var shown: [Airline] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let picked = Self.all.filter { codes.contains($0.id) }
        guard !q.isEmpty else { return picked + Self.all.filter { !codes.contains($0.id) && $0.alliance != nil } }
        return Self.all.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.id.caseInsensitiveCompare(q) == .orderedSame
                || ($0.iata?.caseInsensitiveCompare(q) == .orderedSame)
        }
    }

    var body: some View {
        List(shown) { a in
            Button {
                if let i = codes.firstIndex(of: a.id) { codes.remove(at: i) } else { codes.append(a.id) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: a.name).foregroundStyle(Theme.primary)
                        Text(verbatim: [a.iata, a.id, a.alliance?.title].compactMap { $0 }.joined(separator: " \u{00B7} "))
                            .scaledFont(13)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    if codes.contains(a.id) { Image(systemName: "checkmark").foregroundStyle(Theme.passportAccent) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(codes.contains(a.id) ? .isSelected : [])
        }
        .searchable(text: $query, prompt: Text("Airline name or code"))
        .navigationTitle(Text("Airlines"))
    }
}

// MARK: Expense reports

/// The trips of the history, each with its PDF to share. Business only, or every flight.
struct ExpenseReportsSheet: View {
    var flights: [PastFlight]
    var lookup: (String) -> Airport?
    var traveller: String?
    var units: Units
    @State private var filter: ExpenseTrips.Filter = .business
    @State private var includesNotes = false
    @Environment(\.dismiss) private var dismiss

    private var trips: [ExpenseTrip] { ExpenseTrips.group(flights, filter: filter) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Flights", selection: $filter) {
                        Text("Business").tag(ExpenseTrips.Filter.business)
                        Text("All Flights").tag(ExpenseTrips.Filter.all)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Include Notes", isOn: $includesNotes)
                } footer: {
                    Text("Flights close in time are grouped into a trip. Each PDF lists the flights, times, seats and booking codes, and your notes when you include them. Prices are not included.")
                }
                if trips.isEmpty {
                    Text(filter == .business ? "No business flights yet. Set a flight's reason to Business when you add or edit it."
                         : "No flights to report yet.")
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(trips) { trip in
                    let report = ExpenseReport(trip: trip, traveller: traveller, unit: units.distance, clock: units.clock,
                                               lookup: lookup, includesNotes: includesNotes)
                    ShareLink(item: ExpenseReportFile(report: report), preview: SharePreview(report.fileName)) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: report.title).foregroundStyle(Theme.primary)
                                Text(verbatim: summary(trip, report))
                                    .scaledFont(14)
                                    .foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.passportAccent)
                        }
                    }
                    .accessibilityHint(Text("Shares this trip's report as a PDF"))
                }
            }
            .navigationTitle(Text("Expense Reports"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    /// "12 Mar 2026 · SFO → CDG → SFO".
    private func summary(_ trip: ExpenseTrip, _ report: ExpenseReport) -> String {
        let day = report.day(trip.start, in: report.zone(trip.legs[0].originIcao, fallback: trip.legs[0].originTz))
        return "\(day) \u{00B7} \(trip.route.map(report.code).joined(separator: " \u{2192} "))"
    }
}

/// One trip's PDF for `ShareLink`, drawn when the share sheet asks for it. The file sits in a folder under
/// the history export's prefix, so the launch clean-up (`HistoryExport.removeTemporaryFiles`) sweeps it too.
struct ExpenseReportFile: Transferable, Sendable {
    var report: ExpenseReport

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { try SentTransferredFile($0.write()) }
    }

    func write(in temporary: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let dir = temporary.appending(path: HistoryExport.folderPrefix + "trip-" + UUID().uuidString,
                                      directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: report.fileName)
        try report.pdf().write(to: url, options: .atomic)
        return url
    }
}
