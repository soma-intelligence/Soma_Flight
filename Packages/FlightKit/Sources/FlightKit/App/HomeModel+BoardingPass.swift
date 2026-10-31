import Foundation
import UniformTypeIdentifiers

/// A boarding pass opened from outside the flight sheet, on its way to a followed flight.
public struct PassImport: Identifiable, Sendable {
    public enum State: Sendable, Equatable {
        /// Asking the server for the pass's flight.
        case lookingUp
        /// The flight exists but is not followed: the sheet offers to follow it and keep the pass.
        case follow(Flight)
        /// Following or storing failed; the text says why.
        case failed(String)
        /// No flight matches the pass.
        case notFound
        /// The file is not a boarding pass we can read.
        case unreadable
    }

    public let id = UUID()
    public var pass: BoardingPass?
    public var walletFile: Data?
    public var state: State
}

/// Reads a boarding pass from a file the system hands the app.
public enum PassFile {
    /// The Wallet pass type, "com.apple.pkpass".
    public static let pkpass = UTType("com.apple.pkpass") ?? UTType(filenameExtension: "pkpass") ?? .data

    /// The pass in a `.pkpass` file, or in a picture of a boarding pass barcode, with the Wallet file
    /// when there is one. Opens security scoped URLs (Files, a document picker) for the read.
    public static func read(_ url: URL, near: Date = .now) async throws -> (pass: BoardingPass, walletFile: Data?) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "pkpass" || UTType(filenameExtension: url.pathExtension)?.conforms(to: pkpass) == true {
            return (try WalletPassReader.read(data, near: near), data)
        }
        if let pass = try? WalletPassReader.read(data, near: near) { return (pass, data) }
        return (try await PassBarcodeReader.read(imageData: data, near: near), nil)
    }

    /// True for a URL the app should treat as a boarding pass file (rather than a sign-in link).
    public static func isPassFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "pkpass"
    }
}

extension HomeModel {
    /// A boarding pass file opened in the app: read it, then hand it to `importPass(_:walletFile:)`.
    public func importPass(from url: URL) async {
        do {
            let read = try await PassFile.read(url)
            await importPass(read.pass, walletFile: read.walletFile)
        } catch {
            passImport = PassImport(state: .unreadable)
        }
    }

    /// Keeps a boarding pass with its flight. A followed flight takes it at once and opens; a flight that
    /// is not followed yet is looked up and offered (`followAndKeepPass()`); otherwise the sheet says so.
    public func importPass(_ pass: BoardingPass, walletFile: Data?) async {
        // A pass opened at launch can arrive before My Flights has loaded.
        if !myFlights.hasLoaded { await myFlights.load() }
        if let flight = BoardingPassMatch.flight(for: pass, in: followed, reference: env.reference, lookup: env.lookup) {
            passImport = nil
            if await keep(pass, walletFile: walletFile, on: flight) {
                open(flight: flight)
                showToast("Boarding pass added to \(Format.ident(flight.ident))")
            } else {
                passImport = PassImport(pass: pass, walletFile: walletFile, state: .failed(PassImportFacts.storeFailed))
            }
            return
        }
        var pending = PassImport(pass: pass, walletFile: walletFile, state: .lookingUp)
        passImport = pending
        let query = FlightQuery.ident(pass.ident, date: BoardingPassMatch.searchDate(pass))
        let found = (try? await env.flights.lookup(query)) ?? []
        guard passImport?.id == pending.id else { return }
        if let flight = BoardingPassMatch.flight(for: pass, in: found, reference: env.reference, lookup: env.lookup) {
            pending.state = .follow(flight)
        } else {
            pending.state = .notFound
        }
        passImport = pending
    }

    /// Follows the offered flight, keeps the pass with it and opens it.
    public func followAndKeepPass() async {
        guard let pending = passImport, case .follow(let flight) = pending.state, let pass = pending.pass else { return }
        do {
            try await env.flights.follow(flight.id, notify: true)
        } catch {
            passImport?.state = .failed(error.message)
            return
        }
        let kept = await keep(pass, walletFile: pending.walletFile, on: flight)
        passImport = kept ? nil : PassImport(pass: pass, walletFile: pending.walletFile,
                                             state: .failed(PassImportFacts.storeFailed))
        await didFollow(flight)
        open(flight: flight)
    }

    /// Stores the pass on this device for `flight` and fills its empty booking code, seat and class.
    private func keep(_ pass: BoardingPass, walletFile: Data?, on flight: Flight) async -> Bool {
        var kept = pass
        kept.flightId = flight.id
        do {
            try await env.passes.vault(for: owner).save(kept, walletFile: walletFile)
        } catch {
            return false
        }
        // The details are a nicety here: a failure leaves the pass kept and the tiles as they were.
        if let details = try? await env.flights.followDetails(flight.id),
           let next = BoardingPassMatch.filled(details, from: kept)?.normalized() {
            try? await env.flights.saveFollowDetails(flight.id, next)
        }
        return true
    }
}

/// The import sheet's wording.
enum PassImportFacts {
    static let storeFailed = "Soma Flight could not keep this boarding pass on your phone. Try again."
    static let unreadable = "This file is not a boarding pass Soma Flight can read."
    static func notFound(_ pass: BoardingPass) -> String {
        "We could not find \(BoardingPassMatch.summary(pass)). Check the flight is still scheduled, then try again."
    }
}
