import SwiftUI

/// The Delay Report's colours.
enum DelayInk {
    /// The top bar and year chips.
    static let page = Color(red: 0.25, green: 0.06, blue: 0.05)
    /// The hero, from a lit red under the chips to near black at its foot.
    static let hero = LinearGradient(
        stops: [.init(color: Color(red: 0.52, green: 0.10, blue: 0.08), location: 0),
                .init(color: Color(red: 0.40, green: 0.07, blue: 0.06), location: 0.45),
                .init(color: Color(red: 0.16, green: 0.04, blue: 0.035), location: 1)],
        startPoint: .top, endPoint: .bottom)
    /// The sections under the hero.
    static let sections = Color(red: 0.085, green: 0.075, blue: 0.08)
    static let track = Color.white.opacity(0.08)
    static let late = Color(red: 0.94, green: 0.31, blue: 0.25)
    static let soft = Color(red: 1.0, green: 0.68, blue: 0.62)
    static let amber = Color(red: 1.0, green: 0.73, blue: 0.22)
    static let flap = Color(red: 0.30, green: 0.05, blue: 0.045)

    static func bucket(_ b: DelayReport.Bucket) -> Color {
        switch b {
        case .early: Color(red: 0.24, green: 0.66, blue: 0.40)
        case .onTime: Color(red: 0.45, green: 0.85, blue: 0.47)
        case .late15: Color(red: 0.98, green: 0.80, blue: 0.24)
        case .late30: Color(red: 0.96, green: 0.58, blue: 0.20)
        case .late45: late
        case .canceled, .diverted: Color.white.opacity(0.45)
        }
    }
}

// MARK: - Split-flap board

/// One character on a split-flap board: two halves around a hinge line, the top half falling into place
/// when it appears and again each time its character changes (a new year), the tiles one after another.
/// Straight away with Reduce Motion, and in a rendered image.
struct FlapTile: View {
    var character: Character
    /// Letters of a unit sit dimmer than the digits.
    var dim = false
    var delay: Double = 0
    @ScaledMetric(relativeTo: .largeTitle) private var height: CGFloat = 78
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Goes up once per flip: on appear, then on every new character.
    @State private var flips = 0

    var body: some View {
        let w = height * 0.68
        ZStack {
            face.frame(width: w, height: height)
            // The falling top half, a copy of the face cut at the hinge.
            face.frame(width: w, height: height)
                .mask(VStack(spacing: 0) { Rectangle(); Color.clear })
                .keyframeAnimator(initialValue: 0.0, trigger: flips) { half, angle in
                    half.rotation3DEffect(.degrees(angle), axis: (1, 0, 0), anchor: .center, perspective: 0.5)
                } keyframes: { _ in
                    // Up out of sight, held for this tile's turn, then falling onto the hinge.
                    KeyframeTrack {
                        MoveKeyframe(-90)
                        LinearKeyframe(-90, duration: 0.15 + delay)
                        SpringKeyframe(0, duration: 0.7, spring: .init(response: 0.55, dampingRatio: 0.62))
                    }
                }
            // The hinge: a dark split and the two pins at the sides.
            Rectangle().fill(.black.opacity(0.65)).frame(height: max(1.5, height * 0.02))
            HStack {
                pin
                Spacer()
                pin
            }
        }
        .frame(width: w, height: height)
        .onAppear { if !reduceMotion { flips += 1 } }
        .onChange(of: character) { if !reduceMotion { flips += 1 } }
    }

    private var face: some View {
        RoundedRectangle(cornerRadius: height * 0.09, style: .continuous)
            .fill(LinearGradient(colors: [DelayInk.flap.mix(with: .white, by: 0.07), DelayInk.flap],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: height * 0.09, style: .continuous)
                .strokeBorder(.black.opacity(0.55), lineWidth: 1.5))
            .overlay {
                Text(String(character))
                    .font(.system(size: height * 0.80, weight: .heavy))
                    .fontWidth(.condensed)
                    .foregroundStyle(dim ? Color.white.opacity(0.38) : Color(white: 0.97))
                    .minimumScaleFactor(0.5)
                    // The flap carries the change: the letter itself swaps at once, never rolls or fades.
                    .contentTransition(.identity)
            }
            .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
    }

    private var pin: some View {
        Capsule().fill(.black.opacity(0.7)).frame(width: 3, height: height * 0.12).padding(.horizontal, 1)
    }
}

/// "7 HRS" on flaps: the number's digits bright, the unit's letters dim; the tiles shrink to fit the width.
struct FlapBoard: View {
    var value: String
    var unit: String

    var body: some View {
        let chars = Array(value) + Array(unit)
        ViewThatFits(in: .horizontal) {
            row(chars, gap: 8)
            row(chars, gap: 4).scaleEffect(0.82, anchor: .leading)
            Text(value + " " + unit).scaledFont(56, weight: .heavy).monospacedDigit().foregroundStyle(.white)
        }
    }

    private func row(_ chars: [Character], gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(Array(chars.enumerated()), id: \.offset) { i, c in
                FlapTile(character: c, dim: i >= value.count, delay: Double(i) * 0.09)
            }
        }
    }
}

// MARK: - LED strip

/// A dot-matrix display: monospaced amber type on a dark strip, broken into dots by a fine grid.
struct LEDStrip: View {
    var parts: [String]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                if i > 0 { Spacer(minLength: 10) }
                Text(ui: p)
                    .scaledFont(22, weight: .bold, design: .monospaced)
                    .foregroundStyle(i == 0 ? Color(red: 1.0, green: 0.86, blue: 0.62) : DelayInk.amber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .shadow(color: DelayInk.amber.opacity(0.35), radius: 3)
        .overlay {
            // The dots: rows and columns of the strip's own colour cut through the type.
            Canvas { ctx, size in
                let step: CGFloat = 2.6
                var path = Path()
                var x: CGFloat = 0
                while x < size.width { path.addRect(CGRect(x: x, y: 0, width: 0.6, height: size.height)); x += step }
                var y: CGFloat = 0
                while y < size.height { path.addRect(CGRect(x: 0, y: y, width: size.width, height: 0.6)); y += step }
                ctx.fill(path, with: .color(Self.strip))
            }
            .allowsHitTesting(false)
        }
        .scaledPadding(.horizontal, 14)
        .scaledPadding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Self.strip))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.6), lineWidth: 1.5))
    }

    static let strip = Color(red: 0.11, green: 0.02, blue: 0.02)
}

// MARK: - Worst airline bar

/// The airlines that lost the most time, side by side, each as wide as its share of the late minutes. The
/// first carries the tail of its most delayed type rising out of the block; the others their code.
struct AirlineLossBar: View {
    var losses: [DelayReport.AirlineLoss]
    @Environment(\.reference) private var reference

    /// The three that lost the most, largest first.
    var segments: [(key: String, label: String, minutes: Int)] {
        losses.prefix(3).map { (key: $0.key, label: code($0.key), minutes: $0.minutes) }
    }

    /// Up to three rows, worst first: the airline's mark and name, the minutes, and a thin bar against the
    /// worst one's minutes.
    var body: some View {
        let parts = segments
        let most = max(1, parts.first?.minutes ?? 1)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                row(i, part, share: CGFloat(part.minutes) / CGFloat(most))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.map { "\(name($0.key)), \(DelayFacts.hours($0.minutes)) late" }.joined(separator: "; "))
    }

    private func row(_ i: Int, _ part: (key: String, label: String, minutes: Int), share: CGFloat) -> some View {
        HStack(spacing: 12) {
            AirlineMark(airline: part.key, size: 30, decorative: true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ui: name(part.key))
                        .scaledFont(15, weight: i == 0 ? .semibold : .regular)
                        .foregroundStyle(.white.opacity(i == 0 ? 1 : 0.8))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(DelayFacts.hoursShort(part.minutes))
                        .scaledFont(15, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(i == 0 ? DelayInk.soft : .white.opacity(0.7))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DelayInk.track)
                        Capsule()
                            .fill(DelayInk.late.opacity(i == 0 ? 1 : 0.55))
                            .frame(width: max(6, geo.size.width * share))
                    }
                }
                .frame(height: 5)
            }
        }
    }

    /// Widths in proportion, none under `minimum` so its label fits.
    static func widths(_ minutes: [Int], total: Int, width: CGFloat, minimum: CGFloat) -> [CGFloat] {
        guard !minutes.isEmpty else { return [] }
        var w = minutes.map { CGFloat($0) / CGFloat(total) * width }
        let short = w.indices.filter { w[$0] < minimum }
        let taken = CGFloat(short.count) * minimum
        let rest = w.indices.filter { w[$0] >= minimum }
        let restSum = rest.reduce(0) { $0 + w[$1] }
        for i in short { w[i] = minimum }
        for i in rest where restSum > 0 { w[i] = w[i] / restSum * max(0, width - taken) }
        return w
    }

    /// How far the worst airline's fin may stand above its block, into the room beside the figure.
    static let rise: CGFloat = 18

    private func code(_ key: String) -> String { reference.airline(key)?.iata ?? key }
    private func name(_ key: String) -> String {
        reference.airline(key)?.name ?? key
    }
}

// MARK: - Bars and rows

/// A label, a bar and a figure: one row of the airline or airport rankings.
struct ShareBarRow<Leading: View>: View {
    var title: String
    var share: DelayReport.Share
    var accessibility: String
    @ViewBuilder var leading: Leading

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                leading
                Text(ui: title)
                    .scaledFont(17, weight: .medium)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                (Text("\(share.percent)%").foregroundStyle(Theme.primary)
                 + Text("  \(share.late)/\(share.of)").foregroundStyle(Theme.secondary))
                    .scaledFont(16, weight: .medium)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            Bar(fraction: share.fraction, fill: DelayInk.late)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibility), \(share.percent) percent, \(share.late) of \(share.of)")
    }
}

/// A rounded track with its fill.
struct Bar: View {
    var fraction: Double
    var fill: Color
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DelayInk.track)
                Capsule().fill(fill)
                    .frame(width: fraction > 0 ? max(height, geo.size.width * min(1, fraction)) : 0)
            }
        }
        .frame(height: height)
    }
}

/// A section of the report: its title, a Share button that hands over the section as an image, then the
/// content. The image is made only when the share sheet asks for it (`SectionSnapshot`): rendering all
/// four as the report opened held the main thread through its opening zoom.
struct ReportSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    @Environment(\.reference) private var reference
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
        }
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ui: title)
                .scaledFont(22, weight: .bold)
                .foregroundStyle(Theme.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            ShareLink(item: SectionSnapshot(source: SectionRenderer(page: { AnyView(card) }, scale: max(displayScale, 2))),
                      subject: Text("Soma Flight"),
                      message: Text("\(title), from my Soma Flight Delay Report"),
                      preview: SharePreview("Soma Flight: \(title)", image: Image(systemName: "square.and.arrow.up"))) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                    .scaledPadding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Capsule().fill(.white.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share \(title)")
        }
    }

    /// The section at phone width over the report's dark ground, signed with the app's name.
    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ui: title).scaledFont(22, weight: .bold).foregroundStyle(Theme.primary)
            content
            DelayFacts.signature
        }
        .padding(20)
        .frame(width: 393, alignment: .leading)
        .background(DelayInk.sections)
        .environment(\.colorScheme, .dark)
        .environment(\.reference, reference)
    }
}
