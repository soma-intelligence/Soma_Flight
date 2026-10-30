import SwiftUI

/// Which of the user's details an edit sheet changes.
enum DetailField: String, Identifiable, Sendable {
    case bookingCode, seat, notes
    var id: String { rawValue }
}

extension DetailFacts {
    static let bookingCodeError = "Use 5 to 8 letters or digits"
    static let seatError = "Use a row and a letter, like 23A"
    static let notesError = "Keep notes under \(FollowDetails.maxNotes) characters"

    /// The seat tile's line: "23A · Business", the class alone, or nil when neither is set.
    static func seatLine(_ d: FollowDetails) -> String? {
        let parts = [d.seat, d.seatClass?.title].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Tiles

/// "Booking Code" and "Seat" side by side, "Tap to edit" until set. The booking tile offers a paste
/// button while empty; pasted text is kept only when it is a booking code.
struct DetailTiles: View {
    var details: FollowDetails
    var onEdit: (DetailField) -> Void
    var onPaste: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            tile(icon: "ticket", title: "Booking Code", value: details.bookingCode, field: .bookingCode)
            tile(icon: "carseat.right", title: "Seat", value: DetailFacts.seatLine(details), field: .seat)
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
                Text(title)
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(value ?? "Tap to edit")
                    .scaledFont(15)
                    .foregroundStyle(value == nil ? Theme.secondary : Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .scaledPadding(.horizontal, 16)
            .scaledPadding(.vertical, 15)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
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

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Notes")
                    .scaledFont(20, weight: .bold)
                    .foregroundStyle(Theme.primary)
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.vertical, 14)
                Hairline()
                Text(notes ?? "Tap to edit")
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

/// One sheet per field: the booking code; the seat with its class and the trip's reason; the notes.
/// Save checks the text first and says what is wrong under the field rather than sending it.
struct DetailEditSheet: View {
    var field: DetailField
    var onSave: (FollowDetails) -> Void
    @State private var draft: FollowDetails
    @State private var text: String
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(field: DetailField, details: FollowDetails, onSave: @escaping (FollowDetails) -> Void) {
        self.field = field; self.onSave = onSave
        _draft = State(initialValue: details)
        let start: String = switch field {
        case .bookingCode: details.bookingCode ?? ""
        case .seat: details.seat ?? ""
        case .notes: details.notes ?? ""
        }
        _text = State(initialValue: start)
    }

    private var title: String {
        switch field {
        case .bookingCode: "Booking Code"
        case .seat: "Seat"
        case .notes: "Notes"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch field {
                case .bookingCode:
                    Section {
                        TextField("ABC123", text: $text)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                            .accessibilityLabel("Booking code")
                    } footer: { footer }
                case .seat:
                    Section {
                        TextField("23A", text: $text)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                            .accessibilityLabel("Seat")
                    } footer: { footer }
                    Section("Class") {
                        Picker("Class", selection: $draft.seatClass) {
                            ForEach(SeatClass.allCases, id: \.self) { c in
                                Text(c == .premiumEconomy ? "Premium" : c.title).tag(Optional(c))
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Section("Reason") {
                        Picker("Reason", selection: $draft.reason) {
                            ForEach(TripReason.allCases, id: \.self) { r in Text(r.title).tag(Optional(r)) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                case .notes:
                    Section {
                        TextEditor(text: $text)
                            .frame(minHeight: 180)
                            .accessibilityLabel("Notes")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            footer
                            Text("\(text.unicodeScalars.count) of \(FollowDetails.maxNotes)")
                                .monospacedDigit()
                        }
                    }
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).bold() }
            }
            .onChange(of: text) { error = nil }
        }
    }

    @ViewBuilder private var footer: some View {
        if let error {
            Text(error).foregroundStyle(Theme.veryLate)
        }
    }

    private func save() {
        var next = draft
        switch field {
        case .bookingCode:
            guard let v = FollowDetails.normalizedBookingCode(text) else { error = DetailFacts.bookingCodeError; return }
            next.bookingCode = v
        case .seat:
            guard let v = FollowDetails.normalizedSeat(text) else { error = DetailFacts.seatError; return }
            next.seat = v
        case .notes:
            guard let v = FollowDetails.normalizedNotes(text) else { error = DetailFacts.notesError; return }
            next.notes = v
        }
        onSave(next)
        dismiss()
    }
}
