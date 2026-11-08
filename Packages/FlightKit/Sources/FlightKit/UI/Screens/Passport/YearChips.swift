import SwiftUI

/// Year chips: All-Time then each year with flights. The chosen one sits on a single capsule that slides
/// from chip to chip on a spring, the strip scrolls to keep it in view, and a drag that starts on the
/// capsule scrubs through the years with a selection tick on each. Every figure that hangs on the year
/// changes inside the same animation, so the numbers that carry `rollingDigits()` roll as the pill moves.
/// Reduce Motion cross-fades the capsule in place instead.
struct YearChips: View {
    var years: [Int]
    @Binding var selection: Int?
    /// The chosen chip's fill and the other chips' text.
    var fill: Color = Theme.pill
    var ink: Color = Theme.secondary
    /// False leaves out the All-Time chip (the Year in Review is about one year).
    var allTime = true
    @Environment(\.airportStaticControls) private var staticControls
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Each chip's frame in the strip, by its place in `options`.
    @State private var frames: [Int: CGRect] = [:]
    /// True while a finger scrubs the capsule; the strip waits for the finger to lift before it scrolls.
    @State private var scrubbing = false

    private static let space = "yearChips"
    private var options: [Int?] { allTime ? YearScrub.options(years) : years.map(Optional.some) }
    private var selected: Int? { YearScrub.index(of: selection, in: options) }
    /// Snapshots (no scroll view, nothing measured before the render) and Reduce Motion draw the capsule
    /// on the chip itself, so it fades rather than slides.
    private var slides: Bool { !staticControls && !reduceMotion }

    var body: some View {
        HorizontalStrip(scrolls: !staticControls) {
            ScrollViewReader { proxy in
                HStack(spacing: 4) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, year in
                        chip(i, year).id(YearScrub.id(year))
                    }
                }
                .coordinateSpace(.named(Self.space))
                .background(alignment: .topLeading) { if slides { pill } }
                .overlay(alignment: .topLeading) { if !staticControls { thumb } }
                .scaledPadding(.horizontal, 16)
                .onAppear { proxy.scrollTo(YearScrub.id(selection), anchor: .center) }
                .onChange(of: selection) { _, year in
                    guard !scrubbing else { return }
                    withAnimation(PeriodMotion.animation(reduceMotion: reduceMotion)) {
                        proxy.scrollTo(YearScrub.id(year), anchor: .center)
                    }
                }
                .onChange(of: scrubbing) { _, now in
                    guard !now else { return }
                    withAnimation(PeriodMotion.animation(reduceMotion: reduceMotion)) {
                        proxy.scrollTo(YearScrub.id(selection), anchor: .center)
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func chip(_ index: Int, _ year: Int?) -> some View {
        let on = index == selected
        return Button { choose(year) } label: {
            Text(year.map(String.init) ?? "All-Time")
                .scaledFont(17, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(on ? Theme.primary : ink)
                .scaledPadding(.horizontal, 15)
                .frame(minHeight: 38)
                .background {
                    if !slides {
                        Capsule().fill(fill).overlay(Capsule().strokeBorder(Theme.primary.opacity(0.08), lineWidth: 1))
                            .opacity(on ? 1 : 0)
                    }
                }
                .contentShape(Capsule())
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[index] = $0 }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The one capsule behind the chosen chip, moved (not redrawn) when the choice changes.
    @ViewBuilder private var pill: some View {
        if let i = selected, let f = frames[i] {
            Capsule().fill(fill)
                .overlay(Capsule().strokeBorder(Theme.primary.opacity(0.08), lineWidth: 1))
                .frame(width: f.width, height: f.height)
                .offset(x: f.minX, y: f.minY)
                .allowsHitTesting(false)
        }
    }

    /// An invisible grip over the chosen chip. A drag that starts here scrubs (a tap on the chosen chip
    /// changes nothing anyway); a drag anywhere else scrolls the strip as before.
    @ViewBuilder private var thumb: some View {
        if let i = selected, let f = frames[i] {
            Color.clear
                .contentShape(Capsule())
                .frame(width: f.width, height: f.height)
                .offset(x: f.minX, y: f.minY)
                .gesture(scrub)
                .accessibilityHidden(true)
        }
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in
                scrubbing = true
                let spans = (0..<options.count).compactMap { frames[$0].map { $0.minX...$0.maxX } }
                guard spans.count == options.count, let i = YearScrub.index(atX: value.location.x, spans: spans),
                      i != selected else { return }
                choose(options[i])
            }
            .onEnded { _ in scrubbing = false }
    }

    private func choose(_ year: Int?) {
        guard year != selection else { return }
        withAnimation(PeriodMotion.animation(reduceMotion: reduceMotion)) { selection = year }
    }
}

/// The year strip's arithmetic, kept apart from the view so it can be tested.
enum YearScrub {
    /// The chips in order: All-Time (nil), then the years.
    static func options(_ years: [Int]) -> [Int?] { [nil] + years.map(Optional.some) }

    /// Where `selection` sits in `options`; nil when it is not there.
    static func index(of selection: Int?, in options: [Int?]) -> Int? { options.firstIndex(of: selection) }

    /// A scroll id for a chip: the year, 0 for All-Time (no flight is from year 0).
    static func id(_ year: Int?) -> Int { year ?? 0 }

    /// The chip under `x`, given the chips' horizontal spans in order. Between two chips (the gap), the
    /// nearer one; before the first or past the last, the end one. Nil only without chips.
    static func index(atX x: CGFloat, spans: [ClosedRange<CGFloat>]) -> Int? {
        guard !spans.isEmpty else { return nil }
        if let hit = spans.firstIndex(where: { $0.contains(x) }) { return hit }
        var best = 0
        var gap = CGFloat.infinity
        for (i, s) in spans.enumerated() {
            let d = x < s.lowerBound ? s.lowerBound - x : x - s.upperBound
            if d < gap { gap = d; best = i }
        }
        return best
    }
}

/// How a change of period moves: one spring for the pill, the strip's scroll and the figures.
enum PeriodMotion {
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.35, extraBounce: 0.08)
    }
}

extension View {
    /// The figures under this view roll digit by digit, like a counter, when they change inside an
    /// animation (the year chips set the year in one). `value` gives the direction for a single figure:
    /// up when it grows, down when it shrinks. Under Reduce Motion they cross-fade.
    func rollingDigits(_ value: Double? = nil) -> some View {
        modifier(RollingDigits(value: value))
    }
}

private struct RollingDigits: ViewModifier {
    var value: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.contentTransition(transition)
    }

    private var transition: ContentTransition {
        if reduceMotion { return .opacity }
        if let value { return .numericText(value: value) }
        return .numericText()
    }
}
