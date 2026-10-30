import ImageIO
import Synchronization
import SwiftUI

/// The airline's tail fin as its mark, the way aircraft stats rows show who flies a tail: our own fin
/// render from the brand kit (Resources/Tails, written by Scripts/bundle_side_views.py), on no tile. An
/// airline without a bundled fin falls back to `AirlineMark`.
struct AirlineTailMark: View {
    var airline: String
    var size: CGFloat
    @Environment(\.reference) private var reference

    var body: some View {
        let resolved = TravelFacts.badgeAirline(code: airline, key: airline, reference: reference)
        if let image = resolved.flatMap({ Self.fin($0.id) }) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityLabel(resolved?.name ?? airline)
        } else {
            AirlineMark(airline: airline, size: size)
        }
    }

    private static let cache = FinCache()

    /// The bundled fin for an ICAO code, decoded once; nil when the bundle has none.
    static func fin(_ icao: String) -> CGImage? {
        let key = icao.uppercased()
        if let held = cache.get(key) { return held.image }
        let url = Bundle.module.url(forResource: "tail-\(key)", withExtension: "webp", subdirectory: "Tails")
            ?? Bundle.module.url(forResource: "tail-\(key)", withExtension: "webp")
        let image = url.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        cache.set(key, image)
        return image
    }
}

/// Decoded fins by ICAO code, absences included, so a missing fin is looked up once.
private final class FinCache: Sendable {
    struct Entry: @unchecked Sendable { var image: CGImage? }
    private let store = Mutex<[String: Entry]>([:])
    func get(_ key: String) -> Entry? { store.withLock { $0[key] } }
    func set(_ key: String, _ image: CGImage?) { store.withLock { $0[key] = Entry(image: image) } }
}
