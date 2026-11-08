import Foundation
import Observation

/// The status programmes the traveller typed in (`StatusProgram`), kept on this device only (UserDefaults,
/// as JSON, with the account they belong to). Nothing about them reaches the server. Goals saved under
/// another account read as none, so the next account to sign in never sees them or writes them back.
@MainActor @Observable
public final class StatusPrograms {
    public private(set) var programs: [StatusProgram]
    @ObservationIgnored private let defaults: UserDefaults?
    /// The account the goals belong to (nil: nobody signed in, or the fakes).
    public let owner: UUID?
    nonisolated static let key = "statusPrograms"
    /// More would crowd the Passport.
    public static let limit = 3

    /// What the defaults hold: the goals and whose they are.
    private struct Saved: Codable {
        var owner: UUID?
        var programs: [StatusProgram]
    }

    /// - Parameters:
    ///   - defaults: where they persist; nil keeps them in memory (tests, previews).
    ///   - owner: the account signed in; goals saved for anyone else are not read.
    public init(defaults: UserDefaults? = .standard, owner: UUID? = nil, seed: [StatusProgram] = []) {
        self.defaults = defaults
        self.owner = owner
        let saved = defaults?.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        programs = saved.map { $0.owner == owner ? $0.programs : [] } ?? seed
    }

    public var canAdd: Bool { programs.count < Self.limit }

    /// Adds `program`, or replaces the one with its id. An invalid programme is ignored.
    public func save(_ program: StatusProgram) {
        guard program.isValid else { return }
        if let i = programs.firstIndex(where: { $0.id == program.id }) {
            programs[i] = program
        } else if canAdd {
            programs.append(program)
        }
        persist()
    }

    public func remove(_ id: StatusProgram.ID) {
        programs.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let defaults else { return }
        if programs.isEmpty { defaults.removeObject(forKey: Self.key); return }
        if let data = try? JSONEncoder().encode(Saved(owner: owner, programs: programs)) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
