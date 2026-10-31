import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The flight sheet's boarding pass, under the booking code and seat tiles: the pass as a ticket that
/// opens full screen, or, on a followed flight without one, a row to add it by scanning its barcode,
/// choosing a screenshot or photo of it, or opening its Wallet file (`.pkpass`).
struct BoardingPassSection: View {
    var store: FlightDetailStore
    @State private var showPass = false
    @State private var scanning = false
    @State private var choosingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var importingFile = false
    @State private var working = false
    @State private var problem: String?
    @Environment(\.reference) private var reference
    @Environment(\.units) private var units

    var body: some View {
        Group {
            if let pass = store.boardingPass {
                Button { showPass = true } label: { BoardingPassTicket(pass: pass, flight: store.flight, origin: store.origin) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the boarding pass and its barcode")
            } else if store.takesBoardingPass {
                addRow
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showPass) { fullPass }
        .sheet(isPresented: $scanning) {
            PassScannerSheet { pass in
                scanning = false
                Task { await attach(pass, walletFile: nil) }
            }
        }
        #else
        .sheet(isPresented: $showPass) { fullPass.frame(width: 420, height: 760) }
        #endif
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await readPhoto(item) }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [PassFile.pkpass, .image]) { result in
            guard case .success(let url) = result else { return }
            Task { await readFile(url) }
        }
        .alert("Boarding Pass", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private var fullPass: some View {
        BoardingPassView(store: store, onClose: { showPass = false })
            .environment(\.reference, reference)
            .environment(\.units, units)
    }

    /// "Add Boarding Pass" with the three ways in.
    private var addRow: some View {
        Menu {
            #if os(iOS)
            Button("Scan Barcode", systemImage: "barcode.viewfinder") { scanning = true }
            #endif
            Button("Choose Photo or Screenshot", systemImage: "photo") { choosingPhoto = true }
            Button("Open Wallet Pass File", systemImage: "doc") { importingFile = true }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "ticket")
                    .scaledFont(18, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Boarding Pass")
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(Theme.primary)
                    Text("Keep it here for the gate, even offline")
                        .scaledFont(14)
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 8)
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus")
                        .scaledFont(15, weight: .semibold)
                        .foregroundStyle(Theme.secondary)
                        .accessibilityHidden(true)
                }
            }
            .scaledPadding(.horizontal, 16)
            .scaledPadding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(working)
        .accessibilityLabel("Add Boarding Pass")
    }

    private func readPhoto(_ item: PhotosPickerItem) async {
        working = true
        defer { working = false }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            problem = BoardingPassFacts.photoUnreadable
            return
        }
        do {
            await attach(try await PassBarcodeReader.read(imageData: data), walletFile: nil)
        } catch {
            problem = BoardingPassFacts.message(for: error)
        }
    }

    private func readFile(_ url: URL) async {
        working = true
        defer { working = false }
        do {
            let read = try await PassFile.read(url)
            await attach(read.pass, walletFile: read.walletFile)
        } catch {
            problem = BoardingPassFacts.message(for: error)
        }
    }

    private func attach(_ pass: BoardingPass, walletFile: Data?) async {
        switch await store.attach(pass, walletFile: walletFile) {
        case .attached: showPass = true
        case .otherFlight(let summary): problem = BoardingPassFacts.otherFlight(summary)
        case .failed: problem = PassImportFacts.storeFailed
        }
    }
}

/// The pass as a small ticket on the flight sheet: the airline, the passenger, then seat, group or zone
/// and boarding time, with a barcode glyph that says it opens.
struct BoardingPassTicket: View {
    var pass: BoardingPass
    var flight: Flight?
    var origin: Airport?
    @Environment(\.reference) private var reference
    @Environment(\.units) private var units

    var body: some View {
        let facts = BoardingPassFacts.ticketFacts(pass, flight: flight, origin: origin, clock: units.clock)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AirlineLogo(airline: reference.airline(pass.carrier), code: pass.carrier, size: 34, decorative: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Boarding Pass")
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(Theme.primary)
                    Text([pass.passenger, "\(pass.carrier) \(pass.flightNumber)"].compactMap { $0 }.joined(separator: "  ·  "))
                        .scaledFont(14)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: pass.barcode?.format == .qr || pass.barcode?.format == .aztec ? "qrcode" : "barcode")
                    .scaledFont(26, weight: .regular)
                    .foregroundStyle(Theme.primary)
                    .accessibilityHidden(true)
            }
            if !facts.isEmpty {
                PerforationLine()
                HStack(alignment: .top, spacing: 0) {
                    ForEach(facts, id: \.label) { fact in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.label.uppercased())
                                .scaledFont(11, weight: .semibold)
                                .foregroundStyle(Theme.secondary)
                            Text(fact.value)
                                .scaledFont(20, weight: .semibold)
                                .monospacedDigit()
                                .foregroundStyle(Theme.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .scaledPadding(.all, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The dashed tear line of a ticket.
struct PerforationLine: View {
    var body: some View {
        Line()
            .stroke(Theme.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.midY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

// MARK: - Wording

enum BoardingPassFacts {
    static let photoUnreadable = "Soma Flight could not open that picture."
    static let noBarcode = "There is no boarding pass barcode in that picture. Try a sharper screenshot of the pass."
    static let notBoardingPass = "That code is not a boarding pass."
    static let privacy = "Kept on this device only. Soma Flight never sends your boarding pass to its servers."

    static func otherFlight(_ summary: String) -> String {
        "This boarding pass is for \(summary), not this flight."
    }

    static func message(for error: any Error) -> String {
        switch error {
        case PassBarcodeReader.ReadError.noBarcode: noBarcode
        case PassBarcodeReader.ReadError.notBoardingPass: notBoardingPass
        case WalletPassReader.ReadError.notBoardingPass: "That Wallet pass is not a boarding pass."
        case WalletPassReader.ReadError.missingFlight: "That boarding pass does not say which flight it is for."
        default: PassImportFacts.unreadable
        }
    }

    struct Fact: Equatable {
        var label: String
        var value: String
    }

    /// The ticket's row: seat, group or zone, boarding time; the gate takes the place of a missing one.
    static func ticketFacts(_ pass: BoardingPass, flight: Flight?, origin: Airport?, clock: TimeStyle) -> [Fact] {
        var out: [Fact] = []
        if let seat = pass.seat { out.append(Fact(label: "Seat", value: seat)) }
        if let g = groupFact(pass) { out.append(g) }
        if let b = boarding(pass, origin: origin, clock: clock) { out.append(Fact(label: "Boarding", value: b)) }
        if out.count < 3, let gate = flight?.gateOrigin ?? pass.gate { out.append(Fact(label: "Gate", value: gate)) }
        return Array(out.prefix(3))
    }

    /// "Group 2", "Zone 1", or both.
    static func groupFact(_ pass: BoardingPass) -> Fact? {
        switch (pass.group, pass.zone) {
        case let (g?, z?) where g != z: Fact(label: "Group · Zone", value: "\(g) · \(z)")
        case let (g?, _): Fact(label: "Group", value: g)
        case let (nil, z?): Fact(label: "Zone", value: z)
        default: nil
        }
    }

    /// Boarding time at the origin, or the time as printed.
    static func boarding(_ pass: BoardingPass, origin: Airport?, clock: TimeStyle) -> String? {
        if let t = pass.boardingTime { return Format.clock(t, origin?.timeZone ?? .gmt, clock) }
        return pass.boardingText
    }
}
