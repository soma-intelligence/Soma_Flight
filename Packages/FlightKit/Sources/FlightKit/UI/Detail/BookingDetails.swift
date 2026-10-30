import SwiftUI

/// What the Booking Details sheet holds while open: the typed booking code and seat, the class and
/// reason chips, an inline error per field. Done checks both fields, saves through the store, and on a
/// refusal keeps everything typed and says why.
@MainActor @Observable
final class BookingDetailsModel {
    var draft: FollowDetails
    var code: String
    var seat: String
    var codeError: String?
    var seatError: String?
    private(set) var isSaving = false
    private let original: FollowDetails

    init(details: FollowDetails) {
        draft = details
        original = details
        code = details.bookingCode ?? ""
        seat = details.seat ?? ""
    }

    struct Errors: Error, Equatable {
        var code: String?
        var seat: String?
    }

    /// The details with both fields put in, or the line to show under each field that is not valid.
    static func validated(code: String, seat: String, draft: FollowDetails) -> Result<FollowDetails, Errors> {
        var next = draft
        var errors = Errors()
        if let v = FollowDetails.normalizedBookingCode(code) { next.bookingCode = v } else { errors.code = DetailFacts.bookingCodeError }
        if let v = FollowDetails.normalizedSeat(seat) { next.seat = v } else { errors.seat = DetailFacts.seatError }
        return errors == Errors() ? .success(next) : .failure(errors)
    }

    /// Puts pasted text in the booking code when it reads as one; otherwise says so under the field.
    func paste(_ text: String) {
        if let c = DetailFacts.pastedBookingCode(text) {
            code = c
            codeError = nil
        } else {
            codeError = DetailFacts.pasteHint
        }
    }

    /// Saves through the store; true once stored or when nothing changed (close the sheet), false with
    /// the errors set otherwise.
    func save(to store: FlightDetailStore) async -> Bool {
        guard !isSaving else { return false }
        let next: FollowDetails
        switch Self.validated(code: code, seat: seat, draft: draft) {
        case .failure(let e):
            codeError = e.code; seatError = e.seat
            return false
        case .success(let v): next = v
        }
        codeError = nil; seatError = nil
        if next == original { return true }
        isSaving = true
        defer { isSaving = false }
        if await store.saveDetails(next) { return true }
        seatError = store.detailsError?.message ?? "This flight is no longer in My Flights."
        return false
    }
}

/// The booking code (with a paste button), the seat and where it is (cabin or cockpit chips), then the
/// class and the trip's reason as chips.
/// Done saves both fields and the chips at once; it closes only once the store has the change.
struct BookingDetailsSheet: View {
    var store: FlightDetailStore
    @State private var model: BookingDetailsModel
    @FocusState private var focus: DetailField?
    private let initialFocus: DetailField
    @Environment(\.dismiss) private var dismiss

    init(field: DetailField, store: FlightDetailStore) {
        self.store = store
        initialFocus = field
        _model = State(initialValue: BookingDetailsModel(details: store.details ?? .empty))
    }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            Text("Booking Details").scaledFont(15, weight: .semibold).scaledPadding(.horizontal, 20).scaledPadding(.top, 16)
            content.scaledPadding(.all, 20)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                done.keyboardShortcut(.defaultAction)
            }
            .scaledPadding(.horizontal, 20)
            .scaledPadding(.bottom, 16)
        }
        .frame(width: 440)
        .onAppear { store.clearDetailsError() }
        #else
        NavigationStack {
            ScrollView { content.scaledPadding(.horizontal, 16).scaledPadding(.top, 8).scaledPadding(.bottom, 24) }
                .background(Theme.background)
                .navigationTitle("Booking Details")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { ToolbarItem(placement: .confirmationAction) { done } }
                .interactiveDismissDisabled(model.isSaving)
        }
        .onAppear {
            store.clearDetailsError()
            focus = initialFocus
        }
        #endif
    }

    @ViewBuilder private var done: some View {
        if model.isSaving {
            ProgressView()
        } else {
            Button("Done") { Task { if await model.save(to: store) { dismiss() } } }.bold()
        }
    }

    private var content: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 0) {
            heading("Booking Code")
            field(icon: "ticket", placeholder: "ABC123", text: $model.code, error: model.codeError, which: .bookingCode) {
                if model.code.isEmpty {
                    PasteButton(payloadType: String.self) { strings in
                        guard let first = strings.first else { return }
                        Task { @MainActor in model.paste(first) }
                    }
                    .labelStyle(.titleOnly)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(Theme.secondary)
                }
            }
            .onChange(of: model.code) { model.codeError = nil }

            heading("Seat").scaledPadding(.top, 24)
            field(icon: "carseat.right", placeholder: "23A", text: $model.seat, error: model.seatError, which: .seat) {
                EmptyView()
            }
            .onChange(of: model.seat) { model.seatError = nil }
            ChipFlow {
                ForEach(SeatPosition.allCases, id: \.self) { p in
                    Chip(title: p.title, symbol: Self.positionSymbol(p), selected: model.draft.seatPosition == p) {
                        model.draft.seatPosition = model.draft.seatPosition == p ? nil : p
                    }
                }
            }
            .scaledPadding(.top, 12)

            heading("Class").scaledPadding(.top, 24)
            ChipFlow {
                ForEach(SeatClass.allCases, id: \.self) { c in
                    Chip(title: c == .first ? "First Class" : c.title, badge: Self.classBadge(c),
                         selected: model.draft.seatClass == c) {
                        model.draft.seatClass = model.draft.seatClass == c ? nil : c
                    }
                }
            }

            heading("Reason").scaledPadding(.top, 24)
            ChipFlow {
                ForEach(TripReason.allCases, id: \.self) { r in
                    Chip(title: r.title, symbol: Self.reasonSymbol(r),
                         selected: model.draft.reason == r) {
                        model.draft.reason = model.draft.reason == r ? nil : r
                    }
                }
            }
        }
    }

    /// The letter in the class chip's circle: E, E+, B, F, P.
    static func classBadge(_ c: SeatClass) -> String {
        switch c {
        case .economy: "E"
        case .premiumEconomy: "E+"
        case .business: "B"
        case .first: "F"
        case .private: "P"
        }
    }

    static func reasonSymbol(_ r: TripReason) -> String {
        switch r {
        case .personal: "beach.umbrella.fill"
        case .business: "briefcase.fill"
        case .crew: "airplane"
        }
    }

    static func positionSymbol(_ p: SeatPosition) -> String {
        switch p {
        case .aisle: "figure.walk"
        case .middle: "person.2.fill"
        case .window: "window.vertical.closed"
        case .pilot: "person.fill"
        case .captain: "star.fill"
        case .jumpseat: "chair.fill"
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .scaledFont(20, weight: .semibold)
            .foregroundStyle(Theme.primary)
            .scaledPadding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
    }

    private func field<Trailing: View>(icon: String, placeholder: String, text: Binding<String>, error: String?,
                                       which: DetailField, @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
                    .focused($focus, equals: which)
                    .submitLabel(.done)
                    .accessibilityLabel(which == .seat ? "Seat" : "Booking code")
                trailing()
            }
            .scaledPadding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.pill))
            if let error {
                Text(error)
                    .scaledFont(14)
                    .foregroundStyle(Theme.veryLate)
                    .scaledPadding(.leading, 4)
                    .accessibilityLabel("Error: \(error)")
            }
        }
    }
}

/// One outlined capsule choice: a symbol or a lettered circle, then the title. Filled once chosen.
struct Chip: View {
    var title: String
    var symbol: String?
    var badge: String?
    var selected: Bool
    var action: () -> Void

    init(title: String, symbol: String? = nil, badge: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.badge = badge; self.selected = selected; self.action = action
    }

    var body: some View {
        let ink = selected ? Theme.background : Theme.primary
        Button(action: action) {
            HStack(spacing: 8) {
                if let badge {
                    Text(badge)
                        .scaledFont(badge.count > 1 ? 10 : 12, weight: .heavy)
                        .foregroundStyle(selected ? Theme.primary : Theme.background)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(ink))
                } else if let symbol {
                    Image(systemName: symbol).scaledFont(16, weight: .semibold)
                }
                Text(title).scaledFont(17, weight: .medium)
            }
            .foregroundStyle(ink)
            .lineLimit(1)
            .scaledPadding(.horizontal, 16)
            .scaledPadding(.vertical, 10)
            .background(Capsule().fill(selected ? Theme.primary : .clear))
            .overlay(Capsule().strokeBorder(selected ? .clear : Theme.separator, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Chips left to right, wrapping to the next line when the row is full.
struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let next = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if next > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
