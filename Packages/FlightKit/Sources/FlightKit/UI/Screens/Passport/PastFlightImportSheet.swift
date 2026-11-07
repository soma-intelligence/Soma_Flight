import SwiftUI
import UniformTypeIdentifiers

/// Where an import stands: the preview of a file read, or why it could not be read.
enum PastFlightImportState: Identifiable {
    case preview(PastFlightImport.Preview)
    case failed(String)

    var id: String {
        switch self {
        case .preview(let p): "preview-\(p.rows.count)-\(p.skipped.count)-\(p.duplicates.count)"
        case .failed(let m): "failed-\(m)"
        }
    }

    /// The file types the picker offers (`ImportFile.csvTypes`: CSV, delimited or plain text, or data).
    static let contentTypes = ImportFile.csvTypes

    /// Reads the picked file off the main actor (`ImportFile`: security scope, iCloud download, size) and
    /// previews it against the store's history.
    @MainActor static func read(_ url: URL, store: PassportStore) async -> PastFlightImportState {
        switch await ImportFile.read(url) {
        case .failure(let f): return .failed(f.message)
        case .success(let data):
            do { return .preview(try store.importPreview(data)) } catch { return .failed(error.message) }
        }
    }
}

/// What an import will do before it does it: the flights to add (with what was left out of each), the
/// rows already in the history, and the rows skipped and why. Add stores the flights in batches and
/// closes once they are in.
struct PastFlightImportSheet: View {
    var preview: PastFlightImport.Preview
    var store: PassportStore
    var lookup: (String) -> Airport?
    @State private var isAdding = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            Text("Import Flights").scaledFont(15, weight: .semibold).scaledPadding(.horizontal, 20).scaledPadding(.top, 16)
            ScrollView { content.scaledPadding(.vertical, 12) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                add.keyboardShortcut(.defaultAction)
            }
            .scaledPadding(.horizontal, 20)
            .scaledPadding(.bottom, 16)
        }
        .frame(width: 480, height: 600)
        #else
        NavigationStack {
            ScrollView { content.scaledPadding(.top, 8).scaledPadding(.bottom, 24) }
                .background(Theme.background)
                .navigationTitle("Import Flights")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { add }
                }
                .interactiveDismissDisabled(isAdding)
        }
        #endif
    }

    @ViewBuilder private var add: some View {
        if isAdding {
            ProgressView()
        } else {
            Button(preview.rows.count == 1 ? "Add 1 Flight" : "Add \(preview.rows.count) Flights") {
                Task { await run() }
            }
            .bold()
            .disabled(preview.rows.isEmpty)
        }
    }

    private func run() async {
        isAdding = true
        defer { isAdding = false }
        if await store.importFlights(preview.flights) != nil {
            dismiss()
        } else {
            error = (store.writeError?.message ?? "The flights could not be added.")
                + " Flights already added stay; importing the file again adds only the rest."
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.summary(preview))
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .scaledPadding(.horizontal, 20)
            if let error {
                Text(ui: error)
                    .scaledFont(15, weight: .medium)
                    .foregroundStyle(Theme.veryLate)
                    .scaledPadding(.horizontal, 20)
                    .scaledPadding(.top, 12)
                    .accessibilityLabel("Error: \(error)")
            }
            if !preview.rows.isEmpty {
                CapsHeader("To add", trailing: Self.count(preview.rows.count)).scaledPadding(.horizontal, 20).scaledPadding(.top, 20)
                ForEach(preview.rows) { row in
                    Hairline()
                    VStack(alignment: .leading, spacing: 2) {
                        PastFlightRow(flight: row.flight, origin: lookup(row.flight.originIcao),
                                      destination: lookup(row.flight.destinationIcao))
                        ForEach(row.warnings, id: \.self) { w in
                            Text(ui: w).scaledFont(13).foregroundStyle(Theme.secondary)
                                .scaledPadding(.leading, 18).scaledPadding(.bottom, 4)
                        }
                    }
                }
            }
            skipList("Already in your history", preview.duplicates)
            skipList("Skipped", preview.skipped)
        }
    }

    @ViewBuilder private func skipList(_ title: String, _ skips: [PastFlightImport.Skip]) -> some View {
        if !skips.isEmpty {
            CapsHeader(title, trailing: Self.count(skips.count)).scaledPadding(.horizontal, 20).scaledPadding(.top, 24)
            ForEach(skips) { s in
                Hairline()
                HStack(spacing: 12) {
                    Text("Row \(s.row)").scaledFont(15, weight: .medium).monospacedDigit().foregroundStyle(Theme.secondary)
                    Text(ui: s.reason.message).scaledFont(15).foregroundStyle(Theme.primary)
                    Spacer(minLength: 0)
                }
                .scaledPadding(.horizontal, 20)
                .scaledPadding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
        }
    }

    static func count(_ n: Int) -> String { n == 1 ? "1 row" : "\(n) rows" }

    /// "Read as a Soma Flight export. 12 flights to add, 2 already in your history, 1 skipped."
    static func summary(_ p: PastFlightImport.Preview) -> String {
        let kind = p.format == .somaFlight ? "Read as a Soma Flight export." : "Read as a CSV file."
        let add = p.rows.count == 1 ? "1 flight to add" : "\(p.rows.count) flights to add"
        return "\(kind) \(add), \(p.duplicates.count) already in your history, \(p.skipped.count) skipped."
    }
}

#if DEBUG
#Preview("Import preview") {
    @Previewable @State var store = PassportStore(history: FakeHistoryService())
    let csv = """
    date,from,to,flight,seat
    2019-06-20,SFO,JFK,UA990,23A
    2019-06-21,JFK,SFO,UA991,aisle
    2019-06-21,JFK,SFO,UA991,
    2019-06-22,Somewhere,SFO,,
    2031-01-01,SFO,LAX,,
    """
    let preview = (try? PastFlightImport.preview(Data(csv.utf8), existing: [], airport: PreviewData.airport,
                                                 reference: .bundled(), now: .now))
    return PastFlightImportSheet(preview: preview!, store: store, lookup: PreviewData.airport).preferredColorScheme(.dark)
}
#endif
