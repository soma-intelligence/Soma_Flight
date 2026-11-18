import SwiftUI

/// The first second of a cold launch. It carries on from the launch screen (`LaunchMark`, the jet tile, on
/// black, both at the same place): a glint crosses the tile along the jet's heading, the tile settles, then
/// lifts and fades onto whatever is under it (the sign in globe or the home). Reduce Motion: the tile, then a
/// plain fade. Skipped with `-noSplash YES` (Debug screenshot runs).
struct FlightSplash: View {
    let finished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the glint's centre is on the tile's lower left to upper right diagonal (0 and 1 are the corners).
    @State private var glint: CGFloat = -0.3
    @State private var settled = false
    @State private var leaving = false

    /// The launch screen's tile, in points (`LaunchMark` is 96 pt).
    static let size: CGFloat = 96

    static var enabled: Bool {
        #if DEBUG
        !UserDefaults.standard.bool(forKey: "noSplash")
        #else
        true
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.opacity(leaving ? 0 : 1)
            tile
                .scaleEffect(leaving ? 1.16 : (settled ? 1 : 0.96))
                .opacity(leaving ? 0 : 1)
        }
        .ignoresSafeArea()
        .allowsHitTesting(!leaving)
        .accessibilityHidden(true)
        .task { await play() }
    }

    private var tile: some View {
        Image("LaunchMark")
            .resizable()
            .frame(width: Self.size, height: Self.size)
            .overlay {
                // A soft band of light, tilted like the jet's climb, moving from lower left to upper right.
                LinearGradient(stops: [.init(color: .white.opacity(0), location: 0.42),
                                       .init(color: .white.opacity(0.55), location: 0.5),
                                       .init(color: .white.opacity(0), location: 0.58)],
                               startPoint: UnitPoint(x: glint - 0.5, y: 1.5 - glint),
                               endPoint: UnitPoint(x: glint + 0.5, y: 0.5 - glint))
                    .blendMode(.plusLighter)
            }
            .clipShape(.rect(cornerRadius: Self.size * 0.225, style: .continuous))
    }

    private func play() async {
        if reduceMotion {
            settled = true
            await pause(250)
            withAnimation(.easeOut(duration: 0.25)) { leaving = true }
            await pause(260)
            finished()
            return
        }
        // The tile starts a hair small (as the launch screen hands over) and breathes in while the glint passes.
        await pause(60)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { settled = true }
        withAnimation(.easeInOut(duration: 0.6)) { glint = 1.3 }
        await pause(640)
        withAnimation(.easeIn(duration: 0.26)) { leaving = true }
        await pause(270)
        finished()
    }

    /// A pause that never throws: the splash always ends, even if its task is cancelled.
    private func pause(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}
