import SwiftUI

/// Glyphs a decoding letter cycles through before it lands.
enum DecodeGlyphs {
    static let set = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#%&*+=/<>?")

    /// The same glyph for the same slot and tick, so a frame never flickers twice.
    static func glyph(_ slot: Int, _ tick: Int) -> Character {
        var x = UInt64(truncatingIfNeeded: slot &* 7919 &+ tick &* 104_729 &+ 31)
        x ^= x >> 33; x &*= 0xff51afd7ed558ccd; x ^= x >> 33
        return set[Int(x % UInt64(set.count))]
    }

    /// `count` cycling glyphs, spaces kept where `shape` has them.
    static func scramble(count: Int, tick: Int, shape: [Character]? = nil) -> String {
        String((0..<count).map { i in
            if let shape, i < shape.count, shape[i] == " " { return " " }
            return glyph(i, tick)
        })
    }
}

/// Text that searches for its letters: random glyphs while `text` is nil, then each letter locks in
/// from left to right once it arrives. Plain text after that, so a settled label costs nothing.
struct DecodeText: View {
    var text: String?
    /// Letters shown while nothing has arrived yet.
    var placeholderLength = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrivedAt: Date?
    @State private var settled = false

    private static let tick = 0.055

    var body: some View {
        Group {
            if let text, settled || reduceMotion {
                Text(text)
            } else {
                TimelineView(.periodic(from: .now, by: Self.tick)) { context in
                    Text(frame(at: context.date)).accessibilityLabel(text ?? "Loading")
                }
            }
        }
        .onChange(of: text, initial: true) { _, new in
            if new == nil { arrivedAt = nil; settled = false }
            else if arrivedAt == nil { arrivedAt = .now; schedule(new!) }
        }
    }

    private func perLetter(_ count: Int) -> Double { min(0.04, 0.55 / Double(max(count, 1))) }

    private func schedule(_ text: String) {
        let total = perLetter(text.count) * Double(text.count) + 0.12
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(total))
            if self.text == text { settled = true }
        }
    }

    private func frame(at date: Date) -> String {
        let tick = Int(date.timeIntervalSinceReferenceDate / Self.tick)
        guard let text, let arrivedAt else {
            return DecodeGlyphs.scramble(count: placeholderLength, tick: tick)
        }
        let letters = Array(text)
        let locked = Int(date.timeIntervalSince(arrivedAt) / perLetter(letters.count))
        return String(letters.indices.map { i in
            i < locked || letters[i] == " " ? letters[i] : DecodeGlyphs.glyph(i, tick)
        })
    }
}

/// The airport card while its first load runs: section-shaped lines of cycling glyphs, dim like
/// a board warming up, in place of a spinner.
struct AsciiSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width of each line in glyphs; 0 draws a separator.
    private static let blocks: [[Int]] = [
        [9, 26, 22],
        [0, 18, 30, 30, 24],
        [0, 15, 28, 21],
        [0, 20, 30, 30, 12],
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { context in
            let tick = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate / 0.08)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.blocks.indices, id: \.self) { b in
                    block(Self.blocks[b], index: b, tick: tick)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel("Loading airport")
    }

    private func block(_ widths: [Int], index: Int, tick: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(widths.indices, id: \.self) { i in
                let width = widths[i]
                if width == 0 {
                    Rectangle().fill(Theme.separator).frame(height: 1).scaledPadding(.bottom, 14)
                } else {
                    let slot = index * 100 + i * 37
                    Text(String((0..<width).map { DecodeGlyphs.glyph(slot + $0, tick + slot) }))
                        .scaledFont(i == 0 && index > 0 ? 15 : 13, weight: i == 0 ? .semibold : .regular,
                                    design: .monospaced)
                        .foregroundStyle(Theme.secondary.opacity(i == 0 ? 0.75 : 0.4))
                        .lineLimit(1)
                }
            }
        }
        .scaledPadding(.horizontal, Theme.gutter)
        .scaledPadding(.top, 18)
    }
}
