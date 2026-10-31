import Foundation

public extension WatchSnapshot {
    /// The widgets' four sample flights (`WidgetSnapshot.preview`) with what the watch adds: AF 84's belt
    /// and seat, and UA 1527's seat and boarding pass. For the previews and the complication gallery.
    ///
    /// The pass's modules are a fixed pattern in a QR code's size, not a real code: the watch cannot draw
    /// one (no Core Image), and a preview needs no scanner.
    static func preview(now: Date = .now) -> Self {
        let flights = WidgetSnapshot.preview(now: now)
        let ids = flights.flights.map(\.id)
        let side = 29
        // A stable speckle with the three finder squares, enough to look like a code.
        let modules = (0..<(side * side)).map { i -> Bool in
            let x = i % side, y = i / side
            for (fx, fy) in [(0, 0), (side - 7, 0), (0, side - 7)] where (fx..<fx + 7).contains(x) && (fy..<fy + 7).contains(y) {
                let dx = x - fx, dy = y - fy
                return dx == 0 || dy == 0 || dx == 6 || dy == 6 || ((2...4).contains(dx) && (2...4).contains(dy))
            }
            return (x * 7 + y * 13 + x * y) % 5 < 2
        }
        let pass = WatchPass(format: "qr", message: "M1PREVIEW/SAMPLE", altText: "SAMPLE", passenger: "Camille Laurent",
                             boardingGroup: "2", modules: BarcodeMatrix(width: side, height: side, modules: modules))
        return Self(flights: flights, extras: [
            WatchFlightExtras(id: ids[0], baggageBelt: "5", seat: "6A"),
            WatchFlightExtras(id: ids[1], seat: "21C", pass: pass),
        ])
    }
}
