import ImageIO
import PhotosUI
import SwiftUI

public extension EnvironmentValues {
    /// The signed-in account's travel journal; set only on a Passport flight's sheet (`PastFlightScreen`), so
    /// followed and friends' flights show no journal.
    @Entry var travelJournal: (any TravelJournal)?
}

/// The travel journal on a past flight's sheet: the photos added to the flight in a grid, Add Photos (the
/// system picker, which needs no photo library permission), a photo full screen, and delete.
struct TravelJournalCard: View {
    var journal: any TravelJournal
    var flight: PastFlight.ID

    @State private var photos: [JournalPhoto] = []
    @State private var thumbnails: [JournalPhoto.ID: CGImage] = [:]
    @State private var picked: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var failed = false
    @State private var open: JournalPhoto?

    static let pickLimit = 20

    var body: some View {
        DetailCard {
            CardTitle("Travel Journal", subtitle: photos.isEmpty ? TravelJournalFacts.empty : TravelJournalFacts.count(photos.count))
                .scaledPadding(.bottom, 12)
            if !photos.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                    ForEach(photos) { photo in
                        Button { open = photo } label: { tile(photo) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Photo"))
                            .accessibilityHint(Text("Opens the photo"))
                    }
                }
                .scaledPadding(.bottom, 12)
            }
            PhotosPicker(selection: $picked, maxSelectionCount: Self.pickLimit, matching: .images,
                         preferredItemEncoding: .compatible) {
                Label("Add Photos", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .scaledFont(16, weight: .semibold)
            .foregroundStyle(Theme.passportAccent)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.pill))
            .overlay(alignment: .trailing) { if importing { ProgressView().scaledPadding(.trailing, 14) } }
            .disabled(importing)
            if failed {
                Text("Some photos could not be added.")
                    .scaledFont(14)
                    .foregroundStyle(Theme.secondary)
                    .scaledPadding(.top, 8)
            }
            Text("Copies stay on this device and are never uploaded.")
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .scaledPadding(.top, 8)
        }
        .id("journal")
        .task(id: flight) { await reload() }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task { await add(items) }
        }
        #if os(iOS)
        .fullScreenCover(item: $open) { JournalPhotoViewer(journal: journal, flight: flight, photo: $0, onDelete: delete) }
        #else
        .sheet(item: $open) { JournalPhotoViewer(journal: journal, flight: flight, photo: $0, onDelete: delete) }
        #endif
    }

    private func tile(_ photo: JournalPhoto) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let cg = thumbnails[photo.id] {
                    Image(decorative: cg, scale: 1).resizable().scaledToFill()
                } else {
                    Theme.pill
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func reload() async {
        photos = await journal.photos(for: flight)
        var thumbs: [JournalPhoto.ID: CGImage] = [:]
        for p in photos {
            if let cg = thumbnails[p.id] { thumbs[p.id] = cg; continue }
            if let data = await journal.thumbnail(p.id, of: flight), let cg = JournalPhotoViewer.decode(data) {
                thumbs[p.id] = cg
            }
        }
        thumbnails = thumbs
    }

    private func add(_ items: [PhotosPickerItem]) async {
        importing = true; failed = false
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { failed = true; continue }
                _ = try await journal.add(data, to: flight)
            } catch {
                failed = true
            }
        }
        picked = []
        importing = false
        await reload()
    }

    private func delete(_ photo: JournalPhoto) {
        open = nil
        Task {
            await journal.remove(photo.id, from: flight)
            await reload()
        }
    }
}

/// One photo full screen, with Delete (asks first) and Done.
struct JournalPhotoViewer: View {
    var journal: any TravelJournal
    var flight: PastFlight.ID
    var photo: JournalPhoto
    var onDelete: (JournalPhoto) -> Void
    @State private var image: CGImage?
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    static func decode(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .accessibilityLabel(Text("Photo"))
                } else {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete Photo", systemImage: "trash", role: .destructive) { confirming = true }
                }
            }
            .confirmationDialog("Delete this photo from the journal?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Delete Photo", role: .destructive) { onDelete(photo) }
            } message: {
                Text("The original stays in your photo library.")
            }
        }
        .task { image = await journal.image(photo.id, of: flight).flatMap(Self.decode) }
    }
}

/// The journal's words, English source with French in Localizable.xcstrings.
enum TravelJournalFacts {
    static var empty: String { String(localized: "Photos from this trip, kept on this device", bundle: .main) }
    static func count(_ n: Int) -> String {
        n == 1 ? String(localized: "1 photo", bundle: .main) : String(localized: "\(n) photos", bundle: .main)
    }
}
