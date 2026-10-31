import FlightImportKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Soma Flight" in the share sheet: takes a confirmation email (an `.eml` from Mail or Files, its
/// text, or a PDF itinerary), reads the flights in it on the phone, and leaves it in the App Group for
/// the app, which opens on the review next time it comes to the front. Nothing is uploaded and no
/// network is used; the app deletes the email once it has read it.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareSheetView(model: model) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { await model.read(items.flatMap { $0.attachments ?? [] }) }
    }
}

@MainActor @Observable
final class ShareModel {
    enum State: Equatable {
        case reading
        /// Kept for the app; how many flights it holds and the first ones.
        case kept(count: Int, lines: [String])
        case failed(String)
    }

    var state: State = .reading

    /// The types read, most specific first: an email file keeps its booking markup.
    static let types: [UTType] = [UTType("com.apple.mail.email"), UTType("public.email-message"), .pdf, .html, .plainText]
        .compactMap { $0 }

    func read(_ providers: [NSItemProvider]) async {
        for provider in providers {
            guard let type = Self.types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { continue }
            guard let (data, name) = await Self.load(provider, type: type),
                  let text = SharedEmailFile.text(data: data, name: name ?? (type == .pdf ? "shared.pdf" : nil)) else { continue }
            finish(text: text, name: name)
            return
        }
        state = .failed("Soma Flight can't read this. Share the airline's confirmation email or its PDF itinerary.")
    }

    private func finish(text: String, name: String?) {
        let result = EmailFlightReader.read(Data(text.utf8))
        guard !result.flights.isEmpty else {
            state = .failed("No flights found in this. Share the airline's confirmation email or its PDF itinerary.")
            return
        }
        guard let inbox = ImportInbox.shared(), inbox.put(.init(name: name, text: text)) else {
            state = .failed("Soma Flight couldn't keep this email. Open the app and paste its text in Import.")
            return
        }
        let lines = result.flights.prefix(4).map { f in
            [f.ident.map(Self.spaced), f.origin.flatMap { o in f.destination.map { "\(o) \u{2192} \($0)" } }, f.day.description]
                .compactMap { $0 }.joined(separator: "  ")
        }
        state = .kept(count: result.flights.count, lines: Array(lines))
    }

    /// "AF84" as "AF 84".
    static func spaced(_ ident: String) -> String {
        guard ident.count > 2 else { return ident }
        let split = ident[ident.index(ident.startIndex, offsetBy: 2)].isLetter ? 3 : 2
        return String(ident.prefix(split)) + " " + ident.dropFirst(split)
    }

    /// The attachment's bytes and file name.
    private static func load(_ provider: NSItemProvider, type: UTType) async -> (Data, String?)? {
        let name = provider.suggestedName
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in continuation.resume(returning: data) }
        }
        return data.map { ($0, name) }
    }
}

struct ShareSheetView: View {
    var model: ShareModel
    var done: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                switch model.state {
                case .reading:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading the email").foregroundStyle(.secondary)
                    }
                case .kept(let count, let lines):
                    Text(count == 1 ? "1 flight found" : "\(count) flights found").font(.title3.bold())
                    ForEach(lines, id: \.self) { Text($0).font(.body.monospacedDigit()) }
                    Text("Open Soma Flight to review them, add past flights to your Passport and follow the upcoming ones.")
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Read on this iPhone. The email is never uploaded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("Soma Flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
        }
    }
}
