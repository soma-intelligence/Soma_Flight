import Foundation
import UniformTypeIdentifiers
import FlightImportKit

extension HomeModel {
    /// Lookups the waiting list may spend per load: a long list catches up over a few launches.
    static let followWaitingBudget = 5

    /// Follows the imported flights that have come within two days of leaving, and lets go of those whose
    /// day has passed or that no lookup finds. Runs with every load; a failure keeps the flight waiting.
    public func followWaiting(now: Date = .now) async {
        var budget = Self.followWaitingBudget
        for u in followLater.items {
            guard budget > 0 else { return }
            if ImportFollower.daysAhead(u, now: now, zone: .current) > ImportFollower.reach { continue }
            budget -= 1
            switch await ImportFollower.follow(u, flights: env.flights, reference: env.reference, airport: env.lookup, now: now) {
            case .followed(let flight):
                followLater.remove(u.id)
                await didFollow(flight)
            case .notFound, .gone:
                followLater.remove(u.id)
            case .later, .failed:
                break
            }
        }
    }

    /// Opens the Import screen on the flights in a confirmation email (shared to the app, opened with
    /// it, dropped on it): read here, on the device.
    public func openImport(email text: String, name: String? = nil) {
        imports.readEmail(text, name: name)
        showImport = true
    }

    /// The emails the share extension left in the App Group, read and deleted: the latest opens the
    /// Import screen. Call at start and whenever the app comes to the front.
    public func takeSharedEmails(from inbox: ImportInbox? = ImportInbox.shared()) {
        guard let inbox, inbox.hasItems, let latest = inbox.takeAll().last else { return }
        openImport(email: latest.text, name: latest.name)
    }

    /// True for a file the app reads as a confirmation email: `.eml`, or a PDF or text itinerary.
    nonisolated public static func isEmailFile(_ url: URL) -> Bool {
        url.isFileURL && ["eml", "emlx", "pdf", "txt"].contains(url.pathExtension.lowercased())
    }

    /// A confirmation email file opened with the app or dropped on it.
    public func openImport(emailFile url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= ImportInbox.maxBytes * 4,
              let data = try? Data(contentsOf: url) else {
            imports.fail(.email, "This file could not be read, or is larger than 12 MB.")
            showImport = true
            return
        }
        imports.readEmailFile(data, name: url.lastPathComponent)
        showImport = true
    }

    /// The file types the email picker offers: emails, PDFs and text.
    nonisolated public static let emailFileTypes: [UTType] = [UTType("com.apple.mail.email"), UTType("public.email-message"), .pdf,
                                                  .plainText, .html].compactMap { $0 }
}
