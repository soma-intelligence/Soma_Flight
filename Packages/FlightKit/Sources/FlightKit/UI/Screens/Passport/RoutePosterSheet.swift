import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// The route poster: all time or one year, a paper size and a style, a preview of the page, and Share for
/// the PDF (save to Files, print, AirDrop). Drawn on the device as vectors.
struct RoutePosterSheet: View {
    /// The history as the store maps it (`PassportStore.allFlights`).
    var flights: [PastFlight]
    var name: String?
    var unit: DistanceUnit
    var lookup: (String) -> Airport?
    @State var year: Int?
    @Environment(\.dismiss) private var dismiss

    @State private var format: RoutePoster.Format = .a3
    @State private var style: RoutePoster.Style = .night
    @State private var preview: CGImage?

    private var years: [Int] { YearInReview.years(flights) }
    private var poster: RoutePoster? { RoutePoster.make(flights, year: year, name: name, unit: unit, airport: lookup) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    YearChips(years: years, selection: $year)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    Group {
                        if let preview {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                        } else if poster == nil {
                            // Nothing to draw (a year of canceled flights, airports we cannot place): say so
                            // instead of turning forever.
                            Text("No routes to draw for this period")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 160)
                        } else {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                        }
                    }
                    .accessibilityLabel(Text("Poster preview"))
                    .listRowBackground(Color.clear)
                }
                Section {
                    Picker("Style", selection: $style) {
                        ForEach(RoutePoster.Style.allCases) { Text(ui: $0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Paper Size", selection: $format) {
                        ForEach(RoutePoster.Format.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                } footer: {
                    Text("A vector PDF, sharp at any size. Save it to Files or send it to a printer. It is made on this device.")
                }
                if let poster {
                    Section {
                        ShareLink(item: RoutePosterFile(poster: poster, format: format, style: style),
                                  preview: SharePreview(poster.fileName(format, style: style))) {
                            Label("Share PDF", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle(Text("Route Poster"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: Key(year: year, format: format, style: style)) {
                preview = poster?.preview(format, style: style, width: 1_000)
            }
        }
    }

    private struct Key: Hashable { var year: Int?; var format: RoutePoster.Format; var style: RoutePoster.Style }
}

/// The poster's PDF for `ShareLink`, drawn when the share sheet asks for it, in a folder the launch
/// clean-up sweeps (`HistoryExport.removeTemporaryFiles`).
struct RoutePosterFile: Transferable, Sendable {
    var poster: RoutePoster
    var format: RoutePoster.Format
    var style: RoutePoster.Style

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { try SentTransferredFile($0.write()) }
    }

    func write(in temporary: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let dir = temporary.appending(path: HistoryExport.folderPrefix + "poster-" + UUID().uuidString,
                                      directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: poster.fileName(format, style: style))
        try poster.pdf(format, style: style).write(to: url, options: .atomic)
        return url
    }
}
