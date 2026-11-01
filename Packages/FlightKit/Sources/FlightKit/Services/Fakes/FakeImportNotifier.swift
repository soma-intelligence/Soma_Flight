import Foundation

/// Records what an import would have shown; tests and previews.
@MainActor
public final class FakeImportNotifier: ImportNotifier {
    public var isAppActive: Bool
    public private(set) var prepared = 0
    public private(set) var posted: [(title: String, body: String)] = []

    public init(active: Bool = true) { isAppActive = active }

    public func prepare() async { prepared += 1 }
    public func notify(title: String, body: String) async { posted.append((title, body)) }
    public func beginBackgroundWork() -> Int { 1 }
    public func endBackgroundWork(_ token: Int) {}
}
