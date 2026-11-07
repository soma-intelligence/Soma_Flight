import SwiftUI

/// Which of the user's details an edit sheet changes.
enum DetailField: String, Identifiable, Sendable {
    case bookingCode, seat, notes
    var id: String { rawValue }
}

extension DetailFacts {
    static let bookingCodeError = "Use 5 to 8 letters or digits"
    static let seatError = "Use a row and a letter, like 23A"
    static let notesError = "Use at most \(FollowDetails.maxNotes) characters"
    static let pasteHint = "That is not a booking code"

    /// The booking code in pasted text, or nil when the text is not one (empty text is not one either).
    static func pastedBookingCode(_ text: String) -> String? {
        guard case let code?? = FollowDetails.normalizedBookingCode(text) else { return nil }
        return code
    }

    /// The seat tile's line: "23A · Business", "Captain · Private" (the position stands in for a missing
    /// seat), the class alone, or nil when none is set.
    static func seatLine(_ d: FollowDetails) -> String? {
        let parts = [d.seat ?? d.seatPosition?.title, d.seatClass?.title].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension DetailFacts {
    /// A contact button's caps title as a menu item: "PHONE" as "Phone", "X / TWITTER" as "X / Twitter".
    static func menuTitle(_ caps: String) -> String {
        caps.split(separator: " ").map { w in w.count == 1 ? String(w) : w.prefix(1) + w.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// Apple Maps at the airport, labelled with its name.
    static func mapsURL(_ a: Airport) -> URL? {
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [URLQueryItem(name: "ll", value: "\(a.lat),\(a.lon)"), URLQueryItem(name: "q", value: a.name)]
        return c?.url
    }
}

// MARK: - Tiles

/// "Booking Code" and "Seat" side by side, "Tap to edit" until set. The booking tile offers a paste
/// button while empty; pasted text is kept only when it is a booking code.
struct DetailTiles: View {
    var details: FollowDetails
    var onEdit: (DetailField) -> Void
    var onPaste: ((String) -> Void)?
    /// A short line under the tiles, such as why a paste was not kept.
    var hint: String?
    /// The open editor and the store it saves to: on the Mac the editor shows as a popover on its tile.
    var editing: Binding<DetailField?>?
    var store: FlightDetailStore?
    /// What an unset tile says: "Tap to edit", or "Not noted" where nothing can be edited.
    var empty = "Tap to edit"
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Side by side, stacked at accessibility sizes so "23A · Business" keeps its room.
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                tile(icon: "ticket", title: "Booking Code", value: details.bookingCode, field: .bookingCode)
                tile(icon: "carseat.right", title: "Seat", value: DetailFacts.seatLine(details), field: .seat)
            }
            if let hint {
                Text(ui: hint)
                    .scaledFont(14)
                    .foregroundStyle(Theme.veryLate)
                    .scaledPadding(.leading, 4)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private func tile(icon: String, title: String, value: String?, field: DetailField) -> some View {
        Button { onEdit(field) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon)
                    .scaledFont(20, weight: .medium)
                    .foregroundStyle(Theme.primary)
                    .frame(minHeight: 26, alignment: .leading)
                    .accessibilityHidden(true)
                    .scaledPadding(.bottom, 12)
                Text(ui: title)
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(value ?? empty)
                    .scaledFont(15)
                    .foregroundStyle(value == nil ? Theme.secondary : Theme.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .scaledPadding(.horizontal, 16)
            .scaledPadding(.vertical, 15)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .detailEditor(field, editing: editing, store: store)
        .overlay(alignment: .topTrailing) {
            if field == .bookingCode, value == nil, let onPaste {
                PasteButton(payloadType: String.self) { strings in
                    guard let first = strings.first else { return }
                    Task { @MainActor in onPaste(first) }
                }
                .labelStyle(.titleOnly)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(Theme.accent)
                .scaledPadding(.top, 12)
                .scaledPadding(.trailing, 12)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "Not set")
        .accessibilityHint("Edits the \(title.lowercased())")
    }
}

/// The notes card near the bottom of the sheet; tap to edit.
struct NotesCard: View {
    var notes: String?
    var onEdit: () -> Void
    var empty = "Tap to edit"

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Notes")
                    .scaledFont(20, weight: .bold)
                    .foregroundStyle(Theme.primary)
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.vertical, 14)
                Hairline()
                Text(notes ?? empty)
                    .scaledFont(17)
                    .foregroundStyle(notes == nil ? Theme.secondary.opacity(0.8) : Theme.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.vertical, 14)
            }
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card.opacity(0.5)))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Notes")
        .accessibilityValue(notes ?? "Empty")
        .accessibilityHint("Edits the notes")
    }
}

// MARK: - Edit sheet

extension View {
    /// On the Mac, the editor for `field` opens as a popover anchored on this view while `editing` is
    /// `field`; elsewhere nothing changes (the flight sheet presents it as a sheet).
    @ViewBuilder func detailEditor(_ field: DetailField, editing: Binding<DetailField?>?, store: FlightDetailStore?) -> some View {
        #if os(macOS)
        if let editing, let store {
            popover(isPresented: Binding(get: { editing.wrappedValue == field },
                                         set: { if !$0, editing.wrappedValue == field { editing.wrappedValue = nil } }),
                    arrowEdge: .bottom) {
                if field == .notes {
                    DetailEditSheet(field: field, store: store)
                } else {
                    BookingDetailsSheet(field: field, store: store)
                }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// What an edit sheet holds while open: the typed text, the class and reason, the inline error. Save
/// checks the text, sends it through the store, and on a refusal keeps everything typed and says why.
@MainActor @Observable
final class DetailEditModel {
    let field: DetailField
    var draft: FollowDetails
    var text: String
    var error: String?
    private(set) var isSaving = false

    init(field: DetailField, details: FollowDetails) {
        self.field = field
        draft = details
        text = switch field {
        case .bookingCode: details.bookingCode ?? ""
        case .seat: details.seat ?? ""
        case .notes: details.notes ?? ""
        }
    }

    /// The details with `text` put in `field`, or the line to show under the field when it is not valid.
    static func validated(field: DetailField, text: String, draft: FollowDetails) -> Result<FollowDetails, InputError> {
        var next = draft
        switch field {
        case .bookingCode:
            guard let v = FollowDetails.normalizedBookingCode(text) else { return .failure(InputError(DetailFacts.bookingCodeError)) }
            next.bookingCode = v
        case .seat:
            guard let v = FollowDetails.normalizedSeat(text) else { return .failure(InputError(DetailFacts.seatError)) }
            next.seat = v
        case .notes:
            guard let v = FollowDetails.normalizedNotes(text) else { return .failure(InputError(DetailFacts.notesError)) }
            next.notes = v
        }
        return .success(next)
    }

    struct InputError: Error, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
    }

    /// Saves through the store; true once stored (close the sheet), false with `error` set otherwise.
    func save(to store: FlightDetailStore) async -> Bool {
        guard !isSaving else { return false }
        let next: FollowDetails
        switch Self.validated(field: field, text: text, draft: draft) {
        case .failure(let e): error = e.message; return false
        case .success(let v): next = v
        }
        error = nil
        isSaving = true
        defer { isSaving = false }
        if await store.saveDetails(next) { return true }
        error = store.detailsError?.message ?? "This flight is no longer in My Flights."
        return false
    }
}

/// One sheet per field: the booking code; the seat with its class and the trip's reason; the notes.
/// It closes only once the store has the change; a refusal shows under the field with the text kept.
struct DetailEditSheet: View {
    var store: FlightDetailStore
    @State private var model: DetailEditModel
    @Environment(\.dismiss) private var dismiss

    init(field: DetailField, store: FlightDetailStore) {
        self.store = store
        _model = State(initialValue: DetailEditModel(field: field, details: store.details ?? .empty))
    }

    private var title: String {
        switch model.field {
        case .bookingCode: "Booking Code"
        case .seat: "Seat"
        case .notes: "Notes"
        }
    }

    var body: some View {
        #if os(macOS)
        // A popover shows no toolbar: title on top, the form, then Cancel and Save.
        VStack(alignment: .leading, spacing: 0) {
            Text(ui: title).scaledFont(15, weight: .semibold).scaledPadding(.horizontal, 20).scaledPadding(.top, 16)
            form.formStyle(.grouped).scrollDisabled(model.field != .notes)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if model.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { Task { if await model.save(to: store) { dismiss() } } }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .scaledPadding(.horizontal, 20)
            .scaledPadding(.bottom, 16)
        }
        .frame(width: model.field == .seat ? 420 : 340)
        .frame(minHeight: model.field == .notes ? 340 : nil)
        .onChange(of: model.text) { model.error = nil }
        .onAppear { store.clearDetailsError() }
        #else
        NavigationStack {
            form
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { if await model.save(to: store) { dismiss() } } }.bold()
                    }
                }
            }
            .interactiveDismissDisabled(model.isSaving)
            .onChange(of: model.text) { model.error = nil }
        }
        .onAppear { store.clearDetailsError() }
        #endif
    }

    private var form: some View {
        @Bindable var model = model
        return Form {
            switch model.field {
            case .bookingCode:
                Section {
                    TextField("ABC123", text: $model.text)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .accessibilityLabel("Booking code")
                } footer: { footer }
            case .seat:
                Section {
                    TextField("23A", text: $model.text)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .accessibilityLabel("Seat")
                } footer: { footer }
                Section("Class") {
                    Picker("Class", selection: $model.draft.seatClass) {
                        Text("None").tag(SeatClass?.none)
                        ForEach(SeatClass.allCases, id: \.self) { c in
                            Text(c == .premiumEconomy ? "Premium" : c.title).tag(Optional(c))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section("Reason") {
                    Picker("Reason", selection: $model.draft.reason) {
                        Text("None").tag(TripReason?.none)
                        ForEach(TripReason.allCases, id: \.self) { r in Text(ui: r.title).tag(Optional(r)) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            case .notes:
                Section {
                    TextEditor(text: $model.text)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Notes")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        footer
                        Text("\(model.text.unicodeScalars.count) of \(FollowDetails.maxNotes)")
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let error = model.error {
            Text(ui: error)
                .foregroundStyle(Theme.veryLate)
                .accessibilityLabel("Error: \(error)")
        }
    }
}
