import SwiftUI

/// An aircraft in profile, nose to the left. For now a neutral generic side view in greys whatever the
/// type and airline: liveries and provider side views replace the body (plan Task 12) behind the same
/// signature, so every screen that shows an aircraft already goes through this view.
public struct AircraftImage: View {
    var type: AircraftType?
    var airline: Airline?
    var height: CGFloat

    /// Width over height of the drawing.
    static let aspect: CGFloat = 4.4

    public init(type: AircraftType?, airline: Airline?, height: CGFloat = 72) {
        self.type = type; self.airline = airline; self.height = height
    }

    public var body: some View {
        GenericSideView()
            .frame(width: height * Self.aspect, height: height)
            .accessibilityElement()
            .accessibilityLabel(type.map { "\($0.name) side view" } ?? "Aircraft side view")
    }
}

/// A plain airliner silhouette in a 440 by 100 box: white fuselage, grey belly, fin, wing, engine and a
/// window line.
private struct GenericSideView: View {
    private static let skin = Color(white: 0.97)
    private static let belly = Color(white: 0.80)
    private static let line = Color(white: 0.55)
    private static let dark = Color(white: 0.38)

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 440, sy = size.height / 100
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }

            // Fin and the far tailplane, behind the fuselage.
            var fin = Path()
            fin.move(to: p(338, 54)); fin.addLine(to: p(392, 4)); fin.addLine(to: p(416, 4))
            fin.addLine(to: p(408, 54)); fin.closeSubpath()
            ctx.fill(fin, with: .color(Self.belly))
            ctx.stroke(fin, with: .color(Self.line), lineWidth: 0.8)

            // Fuselage: rounded nose, straight barrel, tail cone rising to the fin.
            var hull = Path()
            hull.move(to: p(30, 70))
            hull.addCurve(to: p(64, 46), control1: p(14, 66), control2: p(24, 48))
            hull.addLine(to: p(360, 44))
            hull.addCurve(to: p(428, 50), control1: p(396, 44), control2: p(420, 46))
            hull.addLine(to: p(428, 56))
            hull.addCurve(to: p(330, 76), control1: p(400, 64), control2: p(360, 76))
            hull.addLine(to: p(60, 78))
            hull.addCurve(to: p(30, 70), control1: p(44, 78), control2: p(34, 75))
            hull.closeSubpath()
            ctx.fill(hull, with: .color(Self.skin))
            // Belly below the window line.
            var belly = Path()
            belly.addRect(CGRect(x: 0, y: 66 * sy, width: size.width, height: size.height))
            ctx.drawLayer { layer in
                layer.clip(to: hull)
                layer.fill(belly, with: .color(Self.belly))
            }
            ctx.stroke(hull, with: .color(Self.line), lineWidth: 0.9)

            // Cockpit and cabin windows.
            var cockpit = Path()
            cockpit.move(to: p(40, 55)); cockpit.addLine(to: p(52, 51)); cockpit.addLine(to: p(56, 56))
            cockpit.addLine(to: p(42, 58)); cockpit.closeSubpath()
            ctx.fill(cockpit, with: .color(Self.dark))
            for i in 0..<34 {
                let x = 80 + CGFloat(i) * 7.6
                ctx.fill(Path(ellipseIn: CGRect(x: x * sx, y: 54 * sy, width: 3 * sx, height: 4 * sy)), with: .color(Self.dark))
            }

            // Near tailplane.
            var tail = Path()
            tail.move(to: p(372, 58)); tail.addLine(to: p(420, 62)); tail.addLine(to: p(420, 66))
            tail.addLine(to: p(380, 64)); tail.closeSubpath()
            ctx.fill(tail, with: .color(Self.belly))
            ctx.stroke(tail, with: .color(Self.line), lineWidth: 0.8)

            // Wing root and engine under it.
            var wing = Path()
            wing.move(to: p(150, 70)); wing.addLine(to: p(250, 72)); wing.addLine(to: p(286, 86))
            wing.addLine(to: p(262, 86)); wing.closeSubpath()
            ctx.fill(wing, with: .color(Self.belly))
            ctx.stroke(wing, with: .color(Self.line), lineWidth: 0.8)
            let engine = Path(roundedRect: CGRect(x: 160 * sx, y: 78 * sy, width: 50 * sx, height: 16 * sy),
                              cornerRadius: 8 * sy)
            ctx.fill(engine, with: .color(Color(white: 0.88)))
            ctx.stroke(engine, with: .color(Self.line), lineWidth: 0.8)
            ctx.fill(Path(CGRect(x: 160 * sx, y: 79 * sy, width: 3 * sx, height: 14 * sy)), with: .color(Self.dark))
        }
    }
}

#if DEBUG
#Preview("Generic side view") {
    VStack(spacing: 20) {
        AircraftImage(type: nil, airline: nil)
        AircraftImage(type: nil, airline: nil, height: 40)
    }
    .padding()
    .background(Color(red: 0.80, green: 0.86, blue: 0.95))
}
#endif
