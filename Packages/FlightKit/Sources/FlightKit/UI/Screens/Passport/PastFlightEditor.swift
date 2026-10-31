import SwiftUI

/// What the Add Past Flight sheet holds while open: the day, the two airports, the typed fields and the
/// chips, and an inline error per field. Save checks everything against `PastFlightRules` (the server's
/// rules) and stores through the Passport store; on a refusal it keeps everything typed and says why.
@MainActor @Observable
final class PastFlightEditorModel {
    /// The flight being edited; nil when adding one.
    let original: PastFlight?
    /// The day picked, as a date in the phone's calendar (only its year, month and day count).
    var day: Date
    var origin: String
    var destination: String
    var ident: String
    /// The airline's ICAO code from the bundled list, or what an import stored.
    var airline: String?
    var aircraftType: String
    var registration: String
    var seat: String
    var seatClass: SeatClass?
    var reason: TripReason?
    var seatPosition: SeatPosition?
    var notes: String
    var errors: [PastFlightRules.Problem: String] = [:]
    /// Why the store refused the last save or delete; shown over the fields.
    var saveError: String?
    private(set) var isSaving = false
    private let airport: (String) -> Airport?

    /// - Parameters:
    ///   - flight: the manual or imported flight to edit; nil to add one.
    ///   - today: the day a new flight starts on.
    init(flight: PastFlight? = nil, airport: @escaping (String) -> Airport?, today: Date = .now,
         calendar: Calendar = .current) {
        original = flight
        self.airport = airport
        if let f = flight {
            // The flight's day at its origin, shown as the same day in the phone's calendar.
            let zone = f.originTz.flatMap(TimeZone.init(identifier:)) ?? airport(f.originIcao)?.timeZone ?? .gmt
            var there = Calendar(identifier: .gregorian)
            there.timeZone = zone
            let c = there.dateComponents([.year, .month, .day], from: f.date)
            day = calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: 12)) ?? f.date
        } else {
            day = today
        }
        origin = flight?.originIcao ?? ""
        destination = flight?.destinationIcao ?? ""
        ident = flight?.ident ?? ""
        airline = flight?.airline
        aircraftType = flight?.aircraftType ?? ""
        registration = flight?.registration ?? ""
        seat = flight?.seat ?? ""
        seatClass = flight?.seatClass
        reason = flight?.reason
        seatPosition = flight?.seatPosition
        notes = flight?.notes ?? ""
    }

    var isEditing: Bool { original != nil }

    /// The flight the fields describe, or the problem of each field that does not read.
    func flight(now: Date, reference: ReferenceData, calendar: Calendar = .current) -> Result<PastFlight, Invalid> {
        var problems: [PastFlightRules.Problem] = []
        func field(_ text: String, _ problem: PastFlightRules.Problem, _ rule: (String) -> String??) -> String? {
            guard let v = rule(text) else { problems.append(problem); return nil }
            return v
        }
        let from = airport(origin)?.id ?? PastFlightRules.airportCode(origin) ?? ""
        let to = airport(destination)?.id ?? PastFlightRules.airportCode(destination) ?? ""
        let zone = airport(from)?.timeZone ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        var date = PastFlightRules.noon(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0, in: zone) ?? day
        // The same day from the same airport keeps the time the flight had (an archived-like instant).
        if let o = original, o.originIcao == from,
           PastFlightRules.dayKey(o.date, in: zone) == PastFlightRules.dayKey(date, in: zone) {
            date = o.date
        }

        var f = original ?? PastFlight(date: date, ident: "", originIcao: from, destinationIcao: to, distanceKm: 0,
                                       source: .manual)
        let moved = f.originIcao != from || f.destinationIcao != to
        f.date = date
        f.originIcao = from
        f.destinationIcao = to
        if moved { f.distanceKm = 0; f.originTz = nil; f.originCountry = nil; f.destinationCountry = nil }
        f.ident = field(ident, .ident, PastFlightRules.ident) ?? ""
        // Without an airline picked, a new or changed flight number names it; an untouched one is left be.
        let identChanged = original.map { $0.ident != f.ident } ?? true
        f.airline = airline ?? (f.ident.isEmpty || !identChanged ? nil : reference.airline(ident: f.ident)?.id)
        f.aircraftType = field(aircraftType, .aircraftType, PastFlightRules.aircraftType)
        f.registration = field(registration, .registration, PastFlightRules.registration)
        f.seat = field(seat, .seat, FollowDetails.normalizedSeat)
        f.notes = field(notes, .notes, FollowDetails.normalizedNotes)
        f.seatClass = seatClass
        f.reason = reason
        f.seatPosition = seatPosition

        let all = Set(problems + PastFlightRules.problems(f, now: now))
        let ordered = Self.order.filter(all.contains)
        return ordered.isEmpty ? .success(f) : .failure(Invalid(problems: ordered))
    }

    /// The fields that do not read, in the order they show.
    struct Invalid: Error, Equatable { var problems: [PastFlightRules.Problem] }

    static let order: [PastFlightRules.Problem] = [
        .date, .origin, .destination, .sameAirports, .ident, .airline, .aircraftType, .registration, .seat, .notes,
    ]

    /// Saves through the store; true once stored (close the sheet), false with the errors set otherwise.
    func save(to store: PassportStore, reference: ReferenceData, now: Date = .now) async -> Bool {
        guard !isSaving else { return false }
        let next: PastFlight
        switch flight(now: now, reference: reference) {
        case .failure(let invalid):
            errors = Dictionary(uniqueKeysWithValues: invalid.problems.map { ($0, $0.message) })
            return false
        case .success(let f): next = f
        }
        errors = [:]
        if next == original { return true }
        isSaving = true
        defer { isSaving = false }
        saveError = nil
        let stored = original == nil ? await store.add(next) : await store.update(next)
        if stored { return true }
        saveError = store.writeError.map(Self.message) ?? "This flight could not be saved."
        return false
    }

    /// Deletes the flight being edited; true once gone.
    func delete(from store: PassportStore) async -> Bool {
        guard let original, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        saveError = nil
        if await store.delete(original.id) { return true }
        saveError = store.writeError.map(Self.message) ?? "This flight could not be deleted."
        return false
    }

    static func message(_ error: APIError) -> String {
        error == .notFound ? "This flight is no longer in your history." : error.message
    }

    // MARK: Search

    /// Airports for a search: by code (ICAO or IATA, exact matches first), then by city or name. Twenty at most.
    static func airports(matching text: String, in all: [Airport]) -> [Airport] {
        let q = key(text)
        guard !q.isEmpty else { return [] }
        let code = text.trimmingCharacters(in: .whitespaces).uppercased()
        let exact = all.filter { $0.id == code || $0.iata == code }
        let rest = all.filter { a in
            !exact.contains(a) && (a.id.hasPrefix(code) || (a.iata?.hasPrefix(code) ?? false)
                || key(a.city).contains(q) || key(a.name).contains(q))
        }
        return Array((exact + rest.sorted { $0.city < $1.city }).prefix(20))
    }

    /// Airlines for a search: by code (ICAO or IATA, exact first), then by name. Twenty at most.
    static func airlines(matching text: String, in all: [Airline]) -> [Airline] {
        let q = key(text)
        guard !q.isEmpty else { return [] }
        let code = text.trimmingCharacters(in: .whitespaces).uppercased()
        let exact = all.filter { $0.id == code || $0.iata == code }
        let rest = all.filter { !exact.contains($0) && key($0.name).contains(q) }
        return Array((exact + rest.sorted { $0.name < $1.name }).prefix(20))
    }

    private static func key(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// The bundled airport list, read once for the sheets' searches.
enum PastFlightDirectory {
    static let shared = AirportDirectory.bundled()
}

/// Add Past Flight (or Edit Past Flight): the day, the route from the bundled airports, then the
/// optional flight number, airline, aircraft and registration, the seat and where it is, the class, the
/// reason and notes, laid out like Booking Details. Save stores it; editing also offers Delete.
struct PastFlightEditorSheet: View {
    var store: PassportStore
    @State private var model: PastFlightEditorModel
    @State private var picking: Picking?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.reference) private var reference

    enum Picking: String, Identifiable { case origin, destination, airline; var id: String { rawValue } }

    init(store: PassportStore, flight: PastFlight? = nil) {
        self.store = store
        _model = State(initialValue: PastFlightEditorModel(flight: flight, airport: PastFlightDirectory.shared.lookup))
    }

    private var title: String { model.isEditing ? "Edit Past Flight" : "Add Past Flight" }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            Text(title).scaledFont(15, weight: .semibold).scaledPadding(.horizontal, 20).scaledPadding(.top, 16)
            ScrollView { content.scaledPadding(.all, 20) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                save.keyboardShortcut(.defaultAction)
            }
            .scaledPadding(.horizontal, 20)
            .scaledPadding(.bottom, 16)
        }
        .frame(width: 480, height: 640)
        .onAppear { store.clearWriteError() }
        .sheet(item: $picking) { pickerSheet($0) }
        #else
        NavigationStack {
            ScrollView { content.scaledPadding(.horizontal, 16).scaledPadding(.top, 8).scaledPadding(.bottom, 24) }
                .background(Theme.background)
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { save }
                }
                .interactiveDismissDisabled(model.isSaving)
        }
        .onAppear { store.clearWriteError() }
        .sheet(item: $picking) { pickerSheet($0) }
        #endif
    }

    @ViewBuilder private var save: some View {
        if model.isSaving {
            ProgressView()
        } else {
            Button("Save") { Task { if await model.save(to: store, reference: reference) { dismiss() } } }.bold()
        }
    }

    @ViewBuilder private func pickerSheet(_ which: Picking) -> some View {
        switch which {
        case .origin:
            AirportPickerSheet(title: "From") { model.origin = $0; model.errors[.origin] = nil; model.errors[.sameAirports] = nil }
        case .destination:
            AirportPickerSheet(title: "To") {
                model.destination = $0; model.errors[.destination] = nil; model.errors[.sameAirports] = nil
            }
        case .airline:
            AirlinePickerSheet { model.airline = $0 }
        }
    }

    private var content: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 0) {
            if let error = model.saveError {
                Text(error)
                    .scaledFont(15, weight: .medium)
                    .foregroundStyle(Theme.veryLate)
                    .scaledPadding(.bottom, 16)
                    .accessibilityLabel("Error: \(error)")
            }
            heading("Date")
            DatePicker("Day", selection: $model.day, in: ...Date.now, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .accessibilityLabel("Day of the flight")
                .onChange(of: model.day) { model.errors[.date] = nil }
            errorLine(.date)

            heading("Route").scaledPadding(.top, 24)
            HStack(spacing: 10) {
                airportPill(model.origin, placeholder: "From", which: .origin)
                Image(systemName: "arrow.right").foregroundStyle(Theme.secondary).accessibilityHidden(true)
                airportPill(model.destination, placeholder: "To", which: .destination)
            }
            errorLine(.origin)
            errorLine(.destination)
            errorLine(.sameAirports)

            heading("Flight").scaledPadding(.top, 24)
            field(icon: "number", placeholder: "Flight number (optional)", text: $model.ident, problem: .ident)
            pill(icon: "building.2", text: airlineName, placeholder: "Airline (optional)") { picking = .airline }
                .scaledPadding(.top, 10)

            heading("Aircraft").scaledPadding(.top, 24)
            field(icon: "airplane", placeholder: "Type, like B738 (optional)", text: $model.aircraftType, problem: .aircraftType)
            if let name = reference.type(model.aircraftType)?.name {
                Text(name).scaledFont(14).foregroundStyle(Theme.secondary).scaledPadding(.leading, 4).scaledPadding(.top, 4)
            }
            field(icon: "tag", placeholder: "Registration (optional)", text: $model.registration, problem: .registration)
                .scaledPadding(.top, 10)

            heading("Seat").scaledPadding(.top, 24)
            field(icon: "carseat.right", placeholder: "23A", text: $model.seat, problem: .seat)
            ChipFlow {
                ForEach(SeatPosition.allCases, id: \.self) { p in
                    Chip(title: p.title, symbol: BookingDetailsSheet.positionSymbol(p), selected: model.seatPosition == p) {
                        model.seatPosition = model.seatPosition == p ? nil : p
                    }
                }
            }
            .scaledPadding(.top, 12)

            heading("Class").scaledPadding(.top, 24)
            ChipFlow {
                ForEach(SeatClass.allCases, id: \.self) { c in
                    Chip(title: c == .first ? "First Class" : c.title, badge: BookingDetailsSheet.classBadge(c),
                         selected: model.seatClass == c) {
                        model.seatClass = model.seatClass == c ? nil : c
                    }
                }
            }

            heading("Reason").scaledPadding(.top, 24)
            ChipFlow {
                ForEach(TripReason.allCases, id: \.self) { r in
                    Chip(title: r.title, symbol: BookingDetailsSheet.reasonSymbol(r), selected: model.reason == r) {
                        model.reason = model.reason == r ? nil : r
                    }
                }
            }

            heading("Notes").scaledPadding(.top, 24)
            TextField("Anything to remember", text: $model.notes, axis: .vertical)
                .scaledFont(17)
                .lineLimit(3...8)
                .scaledPadding(.all, 16)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.pill))
                .onChange(of: model.notes) { model.errors[.notes] = nil }
                .accessibilityLabel("Notes")
            errorLine(.notes)

            if model.isEditing {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Text("Delete Flight").scaledFont(17, weight: .semibold).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.veryLate)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.pill))
                .scaledPadding(.top, 32)
                .disabled(model.isSaving)
                .confirmationDialog("Delete this flight from your history?", isPresented: $confirmDelete,
                                    titleVisibility: .visible) {
                    Button("Delete Flight", role: .destructive) {
                        Task { if await model.delete(from: store) { dismiss() } }
                    }
                }
            }
        }
    }

    private var airlineName: String? {
        model.airline.map { reference.airline($0)?.name ?? $0 }
    }

    private func airportPill(_ code: String, placeholder: String, which: Picking) -> some View {
        let a = PastFlightDirectory.shared.airport(code)
        let text = code.isEmpty ? nil : "\(a?.iata ?? code)  \(a?.city ?? "")".trimmingCharacters(in: .whitespaces)
        return pill(icon: nil, text: text, placeholder: placeholder) { picking = which }
            .accessibilityLabel("\(placeholder): \(a?.name ?? (code.isEmpty ? "not set" : code))")
    }

    private func pill(icon: String?, text: String?, placeholder: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon).scaledFont(18, weight: .medium).foregroundStyle(Theme.secondary)
                        .accessibilityHidden(true)
                }
                Text(text ?? placeholder)
                    .scaledFont(20)
                    .foregroundStyle(text == nil ? Theme.secondary.opacity(0.75) : Theme.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .scaledPadding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.pill))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .scaledFont(20, weight: .semibold)
            .foregroundStyle(Theme.primary)
            .scaledPadding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func errorLine(_ problem: PastFlightRules.Problem) -> some View {
        if let error = model.errors[problem] {
            Text(error)
                .scaledFont(14)
                .foregroundStyle(Theme.veryLate)
                .scaledPadding(.leading, 4)
                .scaledPadding(.top, 6)
                .accessibilityLabel("Error: \(error)")
        }
    }

    private func field(icon: String, placeholder: String, text: Binding<String>,
                       problem: PastFlightRules.Problem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .scaledFont(18, weight: .medium)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityHidden(true)
                TextField(placeholder, text: text)
                    .scaledFont(20)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .submitLabel(.done)
                    .accessibilityLabel(placeholder)
            }
            .scaledPadding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.pill))
            .onChange(of: text.wrappedValue) { model.errors[problem] = nil }
            errorLine(problem)
        }
    }
}

/// Picks an airport from the bundled list by code, city or name. A well-formed code the list does not
/// know can be used as typed (the server fills what its own airport table knows).
struct AirportPickerSheet: View {
    var title: String
    var onPick: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let matches = PastFlightEditorModel.airports(matching: text, in: PastFlightDirectory.shared.all)
        let typed = PastFlightRules.airportCode(text)
        PickerList(title: title, prompt: "Code, city or airport", text: $text, onCancel: { dismiss() }) {
            ForEach(matches) { a in
                PickerRow(title: "\(a.iata ?? a.id)  \(a.city)", subtitle: a.name) { onPick(a.id); dismiss() }
            }
            if let typed, matches.isEmpty {
                PickerRow(title: "Use \u{201C}\(typed)\u{201D}", subtitle: "Not in the app's airport list") {
                    onPick(typed); dismiss()
                }
            }
        }
    }
}

/// Picks an airline from the bundled list by code or name, or clears it.
struct AirlinePickerSheet: View {
    var onPick: (String?) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.reference) private var reference

    var body: some View {
        PickerList(title: "Airline", prompt: "Name or code", text: $text, onCancel: { dismiss() }) {
            PickerRow(title: "No airline", subtitle: nil) { onPick(nil); dismiss() }
            ForEach(PastFlightEditorModel.airlines(matching: text, in: reference.airlines)) { a in
                PickerRow(title: a.name, subtitle: [a.iata, a.id].compactMap { $0 }.joined(separator: " \u{00B7} ")) {
                    onPick(a.id); dismiss()
                }
            }
        }
    }
}

/// A search field over a list of rows, in its own navigation stack (a sheet over the editor).
private struct PickerList<Rows: View>: View {
    var title: String
    var prompt: String
    @Binding var text: String
    var onCancel: () -> Void
    @ViewBuilder var rows: () -> Rows
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField(prompt, text: $text)
                    .scaledFont(17)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .scaledPadding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.pill))
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.vertical, 8)
                ScrollView { LazyVStack(alignment: .leading, spacing: 0) { rows() } }
            }
            .background(Theme.background)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) } }
        }
        #if os(macOS)
        .frame(width: 420, height: 480)
        #endif
        .onAppear { focused = true }
    }
}

private struct PickerRow: View {
    var title: String
    var subtitle: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(17, weight: .medium).foregroundStyle(Theme.primary)
                if let subtitle {
                    Text(subtitle).scaledFont(14).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaledPadding(.horizontal, 20)
            .scaledPadding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Hairline()
    }
}

#if DEBUG
#Preview("Add past flight") {
    PassportEditorPreview(edit: false).preferredColorScheme(.dark)
}
#Preview("Edit past flight, light") {
    PassportEditorPreview(edit: true).preferredColorScheme(.light)
}

private struct PassportEditorPreview: View {
    var edit: Bool
    @State private var store = PassportStore(history: FakeHistoryService())

    var body: some View {
        PastFlightEditorSheet(store: store, flight: edit ? PastFlight(
            date: PreviewData.now.addingTimeInterval(-40 * 86_400), ident: "AF84", originIcao: "LFPG",
            destinationIcao: "KSFO", airline: "AFR", aircraftType: "B77W", seat: "12A", distanceKm: 8_954,
            seatClass: .business, reason: .personal, seatPosition: .window, source: .manual) : nil)
    }
}
#endif
