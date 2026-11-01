import SwiftUI

/// A large, soft illustration for an empty screen: our glossy white jet over a warm coral glow, with route
/// lines drawn around it. Arcs, rings and dots are drawn here, not baked into the picture, so they follow
/// the colour scheme. Decorative: VoiceOver skips it, the text under it speaks. The jet floats gently,
/// and stays still with Reduce Motion.
struct EmptyStateIllustration: View {
    /// What is drawn around the jet, so each empty screen gets its own picture.
    enum Variant {
        /// The jet crossing a dashed great-circle arc inside a passport-stamp ring (Passport).
        case stamp
        /// The jet climbing over a dashed arc between two airports, above a faint horizon (My Flights).
        case climb
    }

    var variant: Variant = .stamp
    /// The width of the picture in points; accessibility text sizes take it down to 72% to leave room for the words.
    var size: CGFloat = 250
    /// The picture in the middle, from the FlightKit asset catalog.
    var asset: String = "empty-jet"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme
    @State private var floating = false

    /// The warm coral of the Ember icon's glow.
    static let coral = Color(light: 0xF0785A, dark: 0xFF7A55)

    private var side: CGFloat { typeSize.isAccessibilitySize ? size * 0.72 : size }
    private var height: CGFloat { variant == .stamp ? side : side * 0.8 }
    private var dark: Bool { scheme == .dark }

    var body: some View {
        ZStack {
            switch variant {
            case .stamp: stampScene
            case .climb: climbScene
            }
        }
        .frame(width: side, height: height)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { floating = true }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { withAnimation(.easeOut(duration: 0.3)) { floating = false } }
        }
    }

    // MARK: Scenes

    private var stampScene: some View {
        let arc = side * 0.62
        return ZStack {
            glow(radius: side * 0.5)
            StampRing()
                .stroke(Theme.secondary.opacity(dark ? 0.28 : 0.32), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                .frame(width: side * 0.86, height: side * 0.86)
            Circle()
                .stroke(Theme.secondary.opacity(dark ? 0.16 : 0.2), lineWidth: 1)
                .frame(width: side * 0.70, height: side * 0.70)
            RouteArc()
                .stroke(Self.coral.opacity(0.75), style: dashed)
                .frame(width: side, height: arc)
                .offset(y: side * 0.04)
            airport(filled: true)
                .offset(x: -side * 0.47, y: arc * 0.44 + side * 0.04)
            airport(filled: false)
                .offset(x: side * 0.47, y: -arc * 0.44 + side * 0.04)
            jet(size: side * 0.66, tilt: -6)
        }
    }

    private var climbScene: some View {
        let span = side * 0.88
        let rise = height * 0.42
        let base = height * 0.3
        return ZStack {
            glow(radius: side * 0.46)
                .offset(y: -height * 0.06)
            Horizon()
                .stroke(Theme.secondary.opacity(dark ? 0.3 : 0.34), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                .frame(width: side, height: 1)
                .offset(y: base + 9)
            ClimbArc()
                .stroke(Self.coral.opacity(0.75), style: dashed)
                .frame(width: span, height: rise)
                .offset(y: base - rise / 2)
            airport(filled: true)
                .offset(x: -span / 2, y: base)
            airport(filled: false)
                .offset(x: span / 2, y: base)
            jet(size: side * 0.54, tilt: 14)
                .offset(x: side * 0.02, y: -height * 0.21)
        }
    }

    // MARK: Pieces

    private var dashed: StrokeStyle { StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 6]) }

    /// The coral bloom behind the jet, a touch stronger in dark where the sheet is near black.
    private func glow(radius: CGFloat) -> some View {
        RadialGradient(colors: [Self.coral.opacity(dark ? 0.6 : 0.42),
                                Self.coral.opacity(dark ? 0.16 : 0.12),
                                Self.coral.opacity(0)],
                       center: .center, startRadius: 0, endRadius: radius)
            .frame(width: radius * 2.4, height: radius * 2.4)
            .blur(radius: 8)
    }

    /// An airport dot: filled where the route starts, a ring where it ends.
    @ViewBuilder private func airport(filled: Bool) -> some View {
        if filled {
            Circle().fill(Self.coral).frame(width: 6, height: 6)
        } else {
            Circle().stroke(Self.coral, lineWidth: 1.5).frame(width: 7, height: 7)
        }
    }

    private func jet(size: CGFloat, tilt: Double) -> some View {
        Image(asset, bundle: .module)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .rotationEffect(.degrees(tilt))
            .shadow(color: Color.black.opacity(dark ? 0.45 : 0.16), radius: 16, y: 14)
            .offset(y: floating ? -6 : 4)
    }
}

/// A great-circle style route from the lower left to the upper right, bowing up like a flight on a flat map.
private struct RouteArc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let start = CGPoint(x: rect.minX + rect.width * 0.03, y: rect.maxY - rect.height * 0.06)
        let end = CGPoint(x: rect.maxX - rect.width * 0.03, y: rect.minY + rect.height * 0.06)
        p.move(to: start)
        p.addQuadCurve(to: end, control: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.minY - rect.height * 0.12))
        return p
    }
}

/// A route between two airports on the same level, its top touching the frame's top edge.
private struct ClimbArc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        // A quadratic's apex sits halfway to its control point.
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                       control: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 2))
        return p
    }
}

/// A flat horizon line under the airports.
private struct Horizon: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.midY))
        return p
    }
}

/// A passport-stamp edge: a ring with two gaps where a stamp's lettering would sit.
private struct StampRing: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: r, startAngle: .degrees(-200), endAngle: .degrees(-40), clockwise: false)
        p.move(to: CGPoint(x: c.x + r * cos(.pi * -20 / 180), y: c.y + r * sin(.pi * -20 / 180)))
        p.addArc(center: c, radius: r, startAngle: .degrees(-20), endAngle: .degrees(140), clockwise: false)
        return p
    }
}

#if DEBUG
#Preview("Stamp") {
    EmptyStateIllustration().padding().background(Theme.background).preferredColorScheme(.dark)
}
#Preview("Climb, light") {
    EmptyStateIllustration(variant: .climb).padding().background(Theme.background).preferredColorScheme(.light)
}
#endif
