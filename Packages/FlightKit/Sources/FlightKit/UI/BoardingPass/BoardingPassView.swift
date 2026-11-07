import SwiftUI

/// The boarding pass full screen, for the gate: the airline, the passenger, the route with its times,
/// gate, boarding time, group or zone, seat, class and booking reference, then the barcode drawn large on
/// white with the screen at full brightness (put back on close). A pass from a Wallet file adds Add to
/// Apple Wallet, or Open in Wallet once it is there. It reads only what is on the device, so it works with
/// no network.
struct BoardingPassView: View {
    var store: FlightDetailStore
    var onClose: () -> Void
    @State private var confirmRemove = false
    @Environment(\.reference) private var reference
    @Environment(\.units) private var units

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let pass = store.boardingPass {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        PassCard(pass: pass, flight: store.flight, origin: store.origin,
                                 destination: store.destination, clock: units.clock)
                        if pass.source == .wallet {
                            WalletActions(store: store)
                        }
                        Text(ui: BoardingPassFacts.privacy)
                            .scaledFont(13)
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .scaledPadding(.horizontal, 12)
                    }
                    .scaledPadding(.horizontal, Theme.gutter)
                    .scaledPadding(.bottom, 32)
                }
            } else {
                Spacer()
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .fullBrightness()
        .confirmationDialog("Remove this boarding pass from Soma Flight?", isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("Remove Boarding Pass", role: .destructive) {
                Task {
                    await store.removeBoardingPass()
                    onClose()
                }
            }
        } message: {
            Text("A copy you added to Apple Wallet stays in Wallet.")
        }
    }

    private var topBar: some View {
        HStack {
            Menu {
                Button("Remove Boarding Pass", systemImage: "trash", role: .destructive) { confirmRemove = true }
            } label: {
                Image(systemName: "ellipsis")
                    .scaledFont(18, weight: .medium)
                    .foregroundStyle(Theme.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .roundGlass()
            .accessibilityLabel("More")
            Spacer()
            Text("Boarding Pass")
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(Theme.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            RoundButton(systemImage: "xmark", label: "Close", action: onClose)
        }
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.top, 12)
        .scaledPadding(.bottom, 12)
    }
}

/// The pass itself: one dark card, torn in two by a perforation, the barcode plate at the bottom.
struct PassCard: View {
    var pass: BoardingPass
    var flight: Flight?
    var origin: Airport?
    var destination: Airport?
    var clock: TimeStyle
    @Environment(\.reference) private var reference

    var body: some View {
        let airline = reference.airline(pass.carrier)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                AirlineLogo(airline: airline, code: pass.carrier, size: 40, decorative: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(airline?.name ?? pass.airlineName ?? pass.carrier)
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    if let day = dayLine {
                        Text(ui: day).scaledFont(14).foregroundStyle(Theme.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text("\(pass.carrier) \(pass.flightNumber)")
                    .scaledFont(20, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(Theme.primary)
            }
            .scaledPadding(.bottom, 20)

            route
                .scaledPadding(.bottom, 20)

            if let name = pass.passenger {
                fact("Passenger", name, large: true)
                    .scaledPadding(.bottom, 16)
            }
            let grid = PassCardFacts.grid(pass, flight: flight, origin: origin, clock: clock)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 3),
                      alignment: .leading, spacing: 16) {
                ForEach(grid, id: \.label) { item in
                    fact(item.label, item.value, note: item.note)
                }
            }

            PerforationLine()
                .scaledPadding(.vertical, 20)

            if let barcode = pass.barcode {
                BarcodePlate(barcode: barcode, caption: PassCardFacts.barcodeCaption(pass))
            } else {
                Text("This pass has no barcode. Show the airline's own pass at the gate.")
                    .scaledFont(15)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .scaledPadding(.all, 20)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
    }

    private var dayLine: String? {
        if let out = flight?.scheduledOut { return ScreenFormat.day(out, origin?.timeZone ?? .gmt) }
        guard let d = pass.departureDay, let date = Calendar(identifier: .gregorian).date(from: d) else { return nil }
        return pass.departureDay?.year == nil ? nil : ScreenFormat.day(date, .current)
    }

    private var route: some View {
        HStack(alignment: .top, spacing: 12) {
            end(code: pass.origin, city: origin?.city, time: flight.flatMap { $0.estimatedOut ?? $0.scheduledOut },
                timeZone: origin?.timeZone, alignment: .leading)
            Image(systemName: "airplane")
                .scaledFont(18, weight: .semibold)
                .foregroundStyle(Theme.secondary)
                .scaledPadding(.top, 14)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            end(code: pass.destination, city: destination?.city, time: flight.flatMap { $0.estimatedIn ?? $0.scheduledIn },
                timeZone: destination?.timeZone, alignment: .trailing)
        }
    }

    private func end(code: String, city: String?, time: Date?, timeZone: TimeZone?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(ui: code)
                .scaledFont(40, weight: .bold)
                .foregroundStyle(Theme.primary)
            if let city {
                Text(ui: city).scaledFont(14).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            if let time, let timeZone {
                Text(Format.clock(time, timeZone, clock))
                    .scaledFont(17, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(Theme.primary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func fact(_ label: String, _ value: String, note: String? = nil, large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: UIText.localized(label).uppercased())
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(Theme.secondary)
            Text(ui: value)
                .scaledFont(large ? 20 : 19, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(Theme.primary)
                .lineLimit(large ? 2 : 1)
                .minimumScaleFactor(0.7)
            if let note {
                Text(ui: note).scaledFont(12, weight: .medium).foregroundStyle(Theme.late)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The barcode on a white plate, as big as the card allows: scanners need dark modules on light.
struct BarcodePlate: View {
    var barcode: PassBarcode
    var caption: String?
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: barcode.format == .pdf417 || barcode.format == .code128 ? 120 : 240)
            if let caption {
                Text(ui: caption)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white))
        .task(id: barcode) { image = PassBarcodeImage.make(barcode, scale: 6) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Boarding pass barcode")
    }
}

enum PassCardFacts {
    struct Item: Equatable {
        var label: String
        var value: String
        /// A short warning under the value ("Was K42").
        var note: String?
    }

    /// Gate, boarding, group or zone, seat, class, booking, in that order; only what is known. The live
    /// gate wins over the printed one, with the printed one noted when they differ.
    static func grid(_ pass: BoardingPass, flight: Flight?, origin: Airport?, clock: TimeStyle) -> [Item] {
        var out: [Item] = []
        let live = flight?.gateOrigin
        if let gate = live ?? pass.gate {
            let changed = live != nil && pass.gate != nil && live != pass.gate
            out.append(Item(label: "Gate", value: gate, note: changed ? "Was \(pass.gate!)" : nil))
        }
        if let b = BoardingPassFacts.boarding(pass, origin: origin, clock: clock) { out.append(Item(label: "Boarding", value: b)) }
        if let g = BoardingPassFacts.groupFact(pass) { out.append(Item(label: g.label, value: g.value)) }
        if let seat = pass.seat { out.append(Item(label: "Seat", value: seat)) }
        if let cabin = pass.cabinTitle { out.append(Item(label: "Class", value: cabin)) }
        if let code = pass.bookingReference { out.append(Item(label: "Booking", value: code)) }
        if let terminal = flight?.terminalOrigin ?? pass.terminal { out.append(Item(label: "Terminal", value: terminal)) }
        if let seq = pass.sequence { out.append(Item(label: "Sequence", value: seq)) }
        return out
    }

    /// The text under the barcode: the pass's own, else the booking reference and sequence.
    static func barcodeCaption(_ pass: BoardingPass) -> String? {
        if let alt = pass.barcode?.altText { return alt }
        let parts = [pass.bookingReference, pass.sequence.map { "SEQ \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}

#if DEBUG
#Preview("Boarding pass, Wallet") {
    @Previewable @State var store: FlightDetailStore?
    Group {
        if let store { BoardingPassView(store: store, onClose: {}) } else { ProgressView() }
    }
    .task { store = await BoardingPassPreview.store() }
    .preferredColorScheme(.dark)
}

#Preview("Ticket on the sheet") {
    BoardingPassTicket(pass: FakeBoardingPass.af84(now: PreviewData.now), flight: PreviewData.enRoute,
                       origin: PreviewData.airport("LFPG"))
        .padding()
        .background(Theme.background)
        .preferredColorScheme(.dark)
}

enum BoardingPassPreview {
    /// AF 84 at the seed's clock, with the fakes' pass.
    @MainActor static func store() async -> FlightDetailStore {
        let flights = FakeFlightService(now: PreviewData.now)
        let s = FlightDetailStore(id: FakeBoardingPass.flightId, flights: flights, airports: FakeAirportService(now: PreviewData.now),
                                  passes: BoardingPassShelf.inMemory(seed: [FakeBoardingPass.af84(now: PreviewData.now)]).vault(for: nil),
                                  lookup: { PreviewData.airport($0) }, simulatesWallet: true)
        await s.load()
        return s
    }
}
#endif
