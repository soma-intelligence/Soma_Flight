import Foundation

/// Stores the flights of an import in the history a batch at a time, so the screen can show how far it
/// got, stop between batches, and say which flights did not go in and why.
///
/// A batch is one insert: the database takes all of its rows or none. When it refuses one (a check, a
/// duplicate key), that batch is sent again one flight at a time, so one bad row costs only itself.
/// When the request cannot reach the server at all (offline, signed out, rate limited), the import stops
/// there and every flight not stored yet is reported with that reason, to retry later.
public enum HistoryImport {
    /// Rows per request: small enough that the bar moves on a slow network, large enough that 2,000
    /// flights take 40 requests.
    public static let batchSize = 50

    public struct Progress: Sendable, Hashable {
        /// Flights handled so far, stored or not.
        public var done: Int
        public var total: Int

        public init(done: Int, total: Int) { self.done = done; self.total = total }

        public var fraction: Double { total == 0 ? 1 : min(1, Double(done) / Double(total)) }
    }

    /// A flight the history did not take.
    public struct Failure: Sendable, Equatable, Identifiable {
        public var flight: PastFlight
        public var error: APIError
        public var id: PastFlight.ID { flight.id }

        public init(flight: PastFlight, error: APIError) { self.flight = flight; self.error = error }

        /// Why, in the words of an import (the app's general messages speak of flight data and last updates).
        public var reason: String {
            switch error {
            case .offline: "You were offline. Retry when you're connected."
            case .unauthorized: "You were signed out. Sign in and retry."
            case .rateLimited: "Too many requests at once. Retry in a few minutes."
            case .providerUnavailable, .decoding, .notFound: "The server didn't answer. Retry in a moment."
            case .rejected(let why): why
            default: error.message
            }
        }
    }

    public struct Outcome: Sendable, Equatable {
        /// As the server stored them, in the order sent.
        public var stored: [PastFlight] = []
        public var failed: [Failure] = []
        /// Flights not sent because the import was stopped.
        public var notSent: [PastFlight] = []

        public var canceled: Bool { !notSent.isEmpty }
    }

    /// The errors that say the server cannot be reached for now: the rest of the import would fail the
    /// same way, one request each.
    static func stopsImport(_ error: APIError) -> Bool {
        switch error {
        case .offline, .unauthorized, .rateLimited, .planLimit: true
        default: false
        }
    }

    /// Sends `flights` to `history`. `progress` runs after every batch (and after every flight of a batch
    /// sent again one by one). Cancelling the calling task stops it before the next batch; a batch already
    /// sent finishes, so a flight is never left half known.
    public static func run(_ flights: [PastFlight], into history: any HistoryService, batchSize: Int = batchSize,
                           progress: @MainActor (Progress) -> Void = { _ in }) async -> Outcome {
        var out = Outcome()
        let total = flights.count
        var done = 0
        await progress(Progress(done: 0, total: total))
        var start = 0
        while start < flights.count {
            if Task.isCancelled {
                out.notSent = Array(flights[start...])
                return out
            }
            let batch = Array(flights[start..<min(start + max(1, batchSize), flights.count)])
            start += batch.count
            switch await send(batch, to: history) {
            case .success(let stored):
                out.stored += stored
                done += batch.count
                await progress(Progress(done: done, total: total))
            case .failure(let error) where stopsImport(error):
                out.failed += (batch + flights[start...]).map { Failure(flight: $0, error: error) }
                await progress(Progress(done: total, total: total))
                return out
            case .failure:
                // One at a time, to keep the good ones and name the bad ones.
                for (i, flight) in batch.enumerated() {
                    switch await send([flight], to: history) {
                    case .success(let stored): out.stored += stored
                    case .failure(let error) where stopsImport(error):
                        out.failed += (batch[i...] + flights[start...]).map { Failure(flight: $0, error: error) }
                        await progress(Progress(done: total, total: total))
                        return out
                    case .failure(let error): out.failed.append(Failure(flight: flight, error: error))
                    }
                    done += 1
                    await progress(Progress(done: done, total: total))
                }
            }
        }
        return out
    }

    /// One request, in a task of its own: cancelling the import does not cut a request the server may
    /// already have committed.
    private static func send(_ batch: [PastFlight], to history: any HistoryService) async -> Result<[PastFlight], APIError> {
        await Task {
            do throws(APIError) { return .success(try await history.addAll(batch)) } catch { return .failure(error) }
        }.value
    }
}
