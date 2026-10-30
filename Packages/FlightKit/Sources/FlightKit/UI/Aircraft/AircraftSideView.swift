import SwiftUI

public enum AircraftStyle: Sendable { case livery, blueprint }

/// An aircraft in profile, nose to the left, from our own geometry (`AircraftGeometry`), sized to its
/// real proportions (overall length over height). `.livery` paints the parts; this first pass paints the
/// plain scheme (white top, light grey belly, grey engines) with a metal sheen on the hull and nacelles.
public struct AircraftSideView: View {
    var type: AircraftType?
    var livery: Livery?
    var style: AircraftStyle

    public init(type: AircraftType?, livery: Livery? = nil, style: AircraftStyle = .livery) {
        self.type = type; self.livery = livery; self.style = style
    }

    public var body: some View {
        let geometry = AircraftGeometry.geometry(type: type)
        AircraftCanvas(geometry: geometry, livery: livery ?? .plain, style: style)
            .aspectRatio(geometry.lengthM / geometry.heightM, contentMode: .fit)
            .accessibilityElement()
            .accessibilityLabel(type.map { "\($0.name) side view" } ?? "Aircraft side view")
    }
}

/// Draws a geometry into its frame (the frame is expected at the geometry's aspect ratio).
struct AircraftCanvas: View {
    var geometry: AircraftGeometry
    var livery: Livery
    var style: AircraftStyle

    var body: some View {
        Canvas { ctx, size in
            let g = geometry
            let s = size.width / g.lengthM
            let toView = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: 0, ty: g.heightM * s)
            func y(_ metres: Double) -> CGFloat { (g.heightM - metres) * s }
            let hair = max(0.4, min(1.1, size.width / 1100))

            if style == .blueprint {
                for shape in g.shapes {
                    ctx.stroke(shape.path.applying(toView), with: .color(.white.opacity(0.9)), lineWidth: 1)
                }
                return
            }

            let ink = Color(red: 0.44, green: 0.47, blue: 0.52).opacity(0.55)
            let top = Color(hexString: livery.fuselageTop) ?? Color(white: 0.97)
            let belly = Color(hexString: livery.belly) ?? Color(white: 0.84)
            let engine = Color(hexString: livery.engines) ?? Color(white: 0.78)
            let cool = Color(red: 0.55, green: 0.62, blue: 0.72)
            let yb = g.fuselageBottomM, yt = g.fuselageTopM
            let hullTop = CGPoint(x: 0, y: y(yt)), hullBottom = CGPoint(x: 0, y: y(yb))
            // Top lightest, a soft shoulder, then cooler toward the belly.
            let skin = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [.init(color: top.mix(with: .black, by: 0.05), location: 0),
                                 .init(color: top.mix(with: .white, by: 0.6), location: 0.12),
                                 .init(color: top, location: 0.45),
                                 .init(color: top.mix(with: cool, by: 0.10), location: 0.80),
                                 .init(color: top.mix(with: cool, by: 0.18), location: 1)]),
                startPoint: hullTop, endPoint: hullBottom)

            func metal(_ base: Color, _ rect: CGRect, light: Double = 0.10, dark: Double = 0.16) -> GraphicsContext.Shading {
                .linearGradient(Gradient(stops: [.init(color: base.mix(with: .black, by: 0.03), location: 0),
                                                 .init(color: base.mix(with: .white, by: light), location: 0.28),
                                                 .init(color: base.mix(with: cool, by: dark * 0.5).mix(with: .black, by: dark * 0.6), location: 1)]),
                                startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY))
            }

            for layer in AircraftLayer.allCases {
                let far = layer == .gearFar || layer == .wingFar || layer == .engineFar
                for shape in g.shapes where shape.layer == layer {
                    let path = shape.path.applying(toView)
                    let box = path.boundingRect
                    switch shape.part {
                    case .hull:
                        ctx.fill(path, with: skin)
                        // Belly below the split, clipped to the hull, cooler and a touch darker underneath.
                        let split = yb + (yt - yb) * livery.bellySplit
                        ctx.drawLayer { inner in
                            inner.clip(to: path)
                            let rect = CGRect(x: 0, y: y(split), width: size.width, height: size.height - y(split))
                            inner.fill(Path(rect), with: .linearGradient(
                                Gradient(colors: [belly.mix(with: .white, by: 0.15), belly.mix(with: cool, by: 0.15).mix(with: .black, by: 0.06)]),
                                startPoint: CGPoint(x: 0, y: y(split)), endPoint: CGPoint(x: 0, y: y(yb - 0.3))))
                        }
                        ctx.stroke(path, with: .color(ink), lineWidth: hair)
                    case .fairing:
                        ctx.fill(path, with: .linearGradient(
                            Gradient(colors: [belly.mix(with: .white, by: 0.35), belly.mix(with: cool, by: 0.12)]),
                            startPoint: CGPoint(x: 0, y: box.minY), endPoint: CGPoint(x: 0, y: box.maxY)))
                        ctx.stroke(path, with: .color(ink.opacity(0.6)), lineWidth: hair * 0.7)
                    case .panelLine:
                        ctx.stroke(path, with: .color(ink.opacity(0.45)), lineWidth: hair * 0.55)
                    case .fin:
                        ctx.fill(path, with: .linearGradient(
                            Gradient(colors: [top.mix(with: .white, by: 0.5), top, top.mix(with: cool, by: 0.12)]),
                            startPoint: CGPoint(x: box.minX, y: box.minY), endPoint: CGPoint(x: box.maxX, y: box.maxY)))
                        ctx.stroke(path, with: .color(ink), lineWidth: hair)
                    case .tailplane:
                        ctx.fill(path, with: metal(Color(white: 0.90), box, light: 0.4, dark: 0.22))
                        ctx.stroke(path, with: .color(ink), lineWidth: hair)
                    case .wing:
                        // Leading edge catches the light; the lower surface falls away cooler.
                        let base = Color(white: far ? 0.70 : 0.86)
                        ctx.fill(path, with: metal(base, box, light: 0.45, dark: 0.30))
                        if !far { ctx.stroke(path, with: .color(ink), lineWidth: hair) }
                    case .flapFairing:
                        ctx.fill(path, with: metal(Color(white: 0.84), box, light: 0.3, dark: 0.2))
                        ctx.stroke(path, with: .color(ink.opacity(0.8)), lineWidth: hair * 0.7)
                    case .winglet:
                        ctx.fill(path, with: metal(top.mix(with: .black, by: 0.04), box, light: 0.4, dark: 0.18))
                        ctx.stroke(path, with: .color(ink), lineWidth: hair)
                    case .pylon:
                        ctx.fill(path, with: metal(Color(white: far ? 0.66 : 0.86), box, light: 0.3, dark: 0.15))
                        if !far { ctx.stroke(path, with: .color(ink.opacity(0.8)), lineWidth: hair * 0.8) }
                    case .nacelle:
                        let base = far ? engine.mix(with: .black, by: 0.25) : engine
                        ctx.fill(path, with: metal(base, box, light: 0.55, dark: 0.30))
                        ctx.stroke(path, with: .color(ink), lineWidth: hair)
                    case .inlet:
                        ctx.fill(path, with: metal(Color(white: far ? 0.72 : 0.97), box, light: 0.5, dark: 0.12))
                    case .fan:
                        ctx.fill(path, with: .color(Color(white: far ? 0.20 : 0.28).opacity(0.85)))
                    case .exhaust:
                        ctx.fill(path, with: metal(Color(white: far ? 0.52 : 0.70), box, light: 0.3, dark: 0.30))
                        ctx.stroke(path, with: .color(ink.opacity(0.8)), lineWidth: hair * 0.6)
                    case .plug:
                        ctx.fill(path, with: metal(Color(white: far ? 0.36 : 0.46), box, light: 0.25, dark: 0.30))
                    case .window:
                        ctx.fill(path, with: .color(Color(red: 0.16, green: 0.18, blue: 0.22)))
                    case .cockpit:
                        ctx.fill(path, with: .linearGradient(
                            Gradient(colors: [Color(red: 0.28, green: 0.31, blue: 0.36), Color(red: 0.10, green: 0.11, blue: 0.13)]),
                            startPoint: CGPoint(x: 0, y: box.minY), endPoint: CGPoint(x: 0, y: box.maxY)))
                    case .mask:
                        ctx.fill(path, with: .color(Color(white: 0.10)))
                    case .door:
                        ctx.stroke(path, with: .color(ink.opacity(0.75)), lineWidth: hair * 0.65)
                    case .cargoDoor:
                        ctx.stroke(path, with: .color(ink.opacity(0.45)), lineWidth: hair * 0.55)
                    case .apu:
                        ctx.fill(path, with: .color(Color(white: 0.45)))
                    case .strut:
                        ctx.fill(path, with: .linearGradient(
                            Gradient(colors: [Color(white: far ? 0.45 : 0.72), Color(white: far ? 0.35 : 0.55)]),
                            startPoint: CGPoint(x: box.minX, y: 0), endPoint: CGPoint(x: box.maxX, y: 0)))
                    case .tyre:
                        ctx.fill(path, with: .color(Color(white: far ? 0.09 : 0.14)))
                    case .hub:
                        ctx.fill(path, with: metal(Color(white: 0.62), box, light: 0.3, dark: 0.2))
                    }
                }
            }
        }
    }
}

extension Color {
    /// `#RRGGBB`, or nil.
    init?(hexString: String) {
        let digits = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

#if DEBUG
#Preview("Side views") {
    VStack(spacing: 16) {
        ForEach([AircraftFamily.a320, .b737, .b737max, .a350, .b777, .b787], id: \.self) { f in
            AircraftSideView(type: AircraftType(id: "", family: f, manufacturer: "", name: f.rawValue))
                .frame(height: 70)
        }
    }
    .padding()
    .background(Color(red: 0.86, green: 0.90, blue: 0.96))
}
#endif
