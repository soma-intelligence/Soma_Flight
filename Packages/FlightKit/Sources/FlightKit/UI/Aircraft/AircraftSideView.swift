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

            let ink = Color(white: 0.50).opacity(0.85)
            let top = Color(hexString: livery.fuselageTop) ?? Color(white: 0.97)
            let belly = Color(hexString: livery.belly) ?? Color(white: 0.84)
            let engine = Color(hexString: livery.engines) ?? Color(white: 0.78)
            let yb = g.fuselageBottomM, yt = g.fuselageTopM
            let hullTop = CGPoint(x: 0, y: y(yt)), hullBottom = CGPoint(x: 0, y: y(yb))
            let skin = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [.init(color: top.mix(with: .black, by: 0.10), location: 0),
                                 .init(color: top, location: 0.32),
                                 .init(color: top.mix(with: .black, by: 0.03), location: 0.75),
                                 .init(color: top.mix(with: .black, by: 0.09), location: 1)]),
                startPoint: hullTop, endPoint: hullBottom)

            func metal(_ base: Color, _ path: Path, light: Double = 0.06, dark: Double = 0.16) -> GraphicsContext.Shading {
                let r = path.boundingRect
                return .linearGradient(Gradient(stops: [.init(color: base.mix(with: .black, by: 0.04), location: 0),
                                                        .init(color: base.mix(with: .white, by: light), location: 0.3),
                                                        .init(color: base.mix(with: .black, by: dark), location: 1)]),
                                       startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: r.maxY))
            }

            for layer in AircraftLayer.allCases {
                let far = layer == .gearFar || layer == .wingFar || layer == .engineFar
                for shape in g.shapes where shape.layer == layer {
                    let path = shape.path.applying(toView)
                    switch shape.part {
                    case .hull:
                        ctx.fill(path, with: skin)
                        // Belly below the split, clipped to the hull, with its own soft sheen.
                        let split = yb + (yt - yb) * livery.bellySplit
                        ctx.drawLayer { inner in
                            inner.clip(to: path)
                            let rect = CGRect(x: 0, y: y(split), width: size.width, height: size.height - y(split))
                            inner.fill(Path(rect), with: .linearGradient(
                                Gradient(colors: [belly, belly.mix(with: .black, by: 0.10)]),
                                startPoint: CGPoint(x: 0, y: y(split)), endPoint: CGPoint(x: 0, y: y(yb - 0.3))))
                            inner.stroke(Path { $0.move(to: CGPoint(x: 0, y: y(split))); $0.addLine(to: CGPoint(x: size.width, y: y(split))) },
                                         with: .color(belly.mix(with: .black, by: 0.12)), lineWidth: hair * 0.6)
                        }
                        ctx.stroke(path, with: .color(ink), lineWidth: hair)
                    case .fin:
                        ctx.fill(path, with: .linearGradient(
                            Gradient(colors: [top.mix(with: .black, by: 0.05), top, top.mix(with: .black, by: 0.06)]),
                            startPoint: CGPoint(x: path.boundingRect.minX, y: 0), endPoint: CGPoint(x: path.boundingRect.maxX, y: 0)))
                        ctx.stroke(path, with: .color(ink), lineWidth: hair)
                    case .tailplane:
                        ctx.fill(path, with: metal(Color(white: 0.88), path))
                        ctx.stroke(path, with: .color(ink), lineWidth: hair)
                    case .wing:
                        ctx.fill(path, with: metal(Color(white: far ? 0.70 : 0.84), path, light: 0.04, dark: 0.18))
                        if !far { ctx.stroke(path, with: .color(ink), lineWidth: hair) }
                    case .flapFairing:
                        ctx.fill(path, with: .color(Color(white: 0.76)))
                        ctx.stroke(path, with: .color(ink.opacity(0.7)), lineWidth: hair * 0.7)
                    case .winglet:
                        ctx.fill(path, with: metal(Color(white: far ? 0.78 : 0.92), path, light: 0.03, dark: 0.12))
                        ctx.stroke(path, with: .color(ink.opacity(far ? 0.5 : 1)), lineWidth: hair)
                    case .pylon:
                        ctx.fill(path, with: .color(Color(white: far ? 0.66 : 0.82)))
                        if !far { ctx.stroke(path, with: .color(ink.opacity(0.8)), lineWidth: hair * 0.8) }
                    case .nacelle:
                        let base = far ? engine.mix(with: .black, by: 0.22) : engine
                        ctx.fill(path, with: metal(base, path, light: 0.22, dark: 0.22))
                        ctx.stroke(path, with: .color(ink), lineWidth: hair)
                    case .inlet:
                        ctx.fill(path, with: .color(Color(white: far ? 0.70 : 0.93)))
                        ctx.stroke(path, with: .color(ink.opacity(0.8)), lineWidth: hair * 0.7)
                    case .exhaust:
                        ctx.fill(path, with: metal(Color(white: far ? 0.50 : 0.66), path, light: 0.10, dark: 0.22))
                        ctx.stroke(path, with: .color(ink.opacity(0.8)), lineWidth: hair * 0.7)
                    case .window:
                        ctx.fill(path, with: .color(Color(red: 0.17, green: 0.19, blue: 0.22)))
                    case .cockpit:
                        ctx.fill(path, with: .linearGradient(
                            Gradient(colors: [Color(red: 0.24, green: 0.27, blue: 0.31), Color(red: 0.11, green: 0.12, blue: 0.14)]),
                            startPoint: CGPoint(x: 0, y: path.boundingRect.minY), endPoint: CGPoint(x: 0, y: path.boundingRect.maxY)))
                    case .mask:
                        ctx.fill(path, with: .color(Color(white: 0.09)))
                    case .door:
                        ctx.stroke(path, with: .color(Color(white: 0.55).opacity(0.75)), lineWidth: hair * 0.75)
                    case .cargoDoor:
                        ctx.stroke(path, with: .color(Color(white: 0.55).opacity(0.4)), lineWidth: hair * 0.6)
                    case .apu:
                        ctx.fill(path, with: .color(Color(white: 0.52)))
                    case .strut:
                        ctx.fill(path, with: metal(Color(white: far ? 0.48 : 0.66), path))
                    case .tyre:
                        ctx.fill(path, with: .color(Color(white: far ? 0.10 : 0.16)))
                    case .hub:
                        ctx.fill(path, with: .color(Color(white: 0.58)))
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
