import Foundation

/// Where the share extension leaves a confirmation email for the app: a folder in the App Group
/// container, on this device only. The app takes each item once (reading it deletes it), so an email
/// stays on the phone only until the app has read it. Nothing here touches the network.
public struct ImportInbox: Sendable {
    /// What was shared: the email's raw source (`.eml`), its text, or a PDF's text.
    public struct Item: Codable, Sendable, Hashable, Identifiable {
        public var id: UUID
        public var received: Date
        /// The file name shared, for the screen ("Booking.eml"); nil for shared text.
        public var name: String?
        /// The raw email, the pasted text or the PDF's text.
        public var text: String

        public init(id: UUID = UUID(), received: Date = .now, name: String? = nil, text: String) {
            self.id = id; self.received = received; self.name = name; self.text = text
        }
    }

    public static let appGroup = "group.me.somalabs.flight"
    /// An email larger than this is not kept (a real confirmation is well under it).
    public static let maxBytes = 3_000_000

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The App Group's inbox; nil where the app has no group (the Mac, tests).
    public static func shared() -> ImportInbox? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { ImportInbox(directory: $0.appendingPathComponent("ImportInbox", isDirectory: true)) }
    }

    /// Leaves an item for the app; false when it is too large or cannot be written.
    @discardableResult
    public func put(_ item: Item) -> Bool {
        guard let data = try? JSONEncoder().encode(item), data.count <= Self.maxBytes else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            // Unreadable while the phone is locked.
            let options: Data.WritingOptions = [.atomic, .completeFileProtection]
            #else
            let options: Data.WritingOptions = [.atomic]
            #endif
            try data.write(to: directory.appendingPathComponent("\(item.id.uuidString).json"), options: options)
            return true
        } catch {
            return false
        }
    }

    /// Every item left, oldest first, deleted from the folder as it is read.
    public func takeAll() -> [Item] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var items: [Item] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let item = try? JSONDecoder().decode(Item.self, from: data) {
                items.append(item)
            }
            try? FileManager.default.removeItem(at: file)
        }
        return items.sorted { $0.received < $1.received }
    }

    /// True when something is waiting.
    public var hasItems: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).contains { $0.hasSuffix(".json") }
    }
}

/// Turns a shared file into the text the email reader takes: an `.eml` or text file as is, a PDF's text.
public enum SharedEmailFile {
    public static func text(data: Data, name: String?) -> String? {
        let ext = (name as NSString?)?.pathExtension.lowercased() ?? ""
        if ext == "pdf" || data.starts(with: Array("%PDF".utf8)) { return PDFText.text(data) }
        let text = EmailMessage.decodeText(data)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
