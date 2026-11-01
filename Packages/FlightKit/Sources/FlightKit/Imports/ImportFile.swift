import Foundation
import UniformTypeIdentifiers

/// Reading a file the system file picker hands over, off the main actor.
///
/// The picker gives a security-scoped URL to the file where it lives (iCloud Drive, On My iPhone, another
/// app's folder). It is read inside that scope through a file coordinator, which downloads a file that
/// iCloud has only as a placeholder; its size is checked once read, since a placeholder may have none.
public enum ImportFile {
    /// The largest export read: a history of 5,000 flights in the other tracker's 33 columns is about 3 MB.
    public static let maxBytes = 10_000_000

    public enum Failure: Error, Sendable, Hashable {
        case unreadable
        case tooLarge
        case empty

        public var message: String {
            switch self {
            case .unreadable: "This file couldn't be opened. If it's in iCloud Drive, open it once in Files so it downloads, then pick it again."
            case .tooLarge: "This file is larger than 10 MB. Split it and import each part."
            case .empty: "This file is empty."
            }
        }
    }

    /// The types a CSV picker offers. A `.csv` file can reach it typed as CSV, as delimited or plain
    /// text, or (shared from another app, or with its name changed) as bare data; the reader decides from
    /// the content, and says so when it is not a flight list.
    public static let csvTypes: [UTType] = [.commaSeparatedText, .delimitedText, .tabSeparatedText, .plainText, .text, .data]

    @concurrent public static func read(_ url: URL, maxBytes: Int = maxBytes) async -> Result<Data, Failure> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes { return .failure(.tooLarge) }
        var data: Data?
        var coordinated: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinated) { readable in
            data = try? Data(contentsOf: readable, options: .mappedIfSafe)
        }
        // Without a coordinator (a plain local path), the file is read as is.
        if data == nil { data = try? Data(contentsOf: url) }
        guard let data else { return .failure(.unreadable) }
        if data.count > maxBytes { return .failure(.tooLarge) }
        if data.isEmpty { return .failure(.empty) }
        return .success(Data(data))
    }
}

/// The Import screen's file picker: which source it picks for, kept until its result is handled.
///
/// SwiftUI sets the picker's `isPresented` binding back to false before it calls `onCompletion`. The
/// first screen kept the source only in that binding, so it was already cleared when the picked file came
/// back, and the file was dropped without a word (the 2026-10-31 "Import from Flighty does nothing"). Here
/// closing the picker leaves the source alone; `take` hands it over once, with the result.
struct ImportPicker<Kind: Hashable>: Hashable {
    private(set) var kind: Kind?
    var isPresented = false

    mutating func open(_ kind: Kind) {
        self.kind = kind
        isPresented = true
    }

    /// The source the result belongs to, once; nil when nothing was opened.
    mutating func take() -> Kind? {
        defer { kind = nil; isPresented = false }
        return kind
    }
}
