import SwiftUI
import FlightCore

// MARK: - Panel

/// The blueprint's blue paper with a fine grid ruled on it (every 8 pt, a stronger line every 40 pt), behind
/// the content.
public struct BlueprintPanel<Content: View>: View {
    var content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content.background(BlueprintGrid())
    }
}

/// The paper itself.
struct BlueprintGrid: View {
    static let cell: CGFloat = 8

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.blueprint))
            var fine = Path(), coarse = Path()
            var i = 0
            var x: CGFloat = 0
            while x <= size.width {
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                if i % 5 == 0 { coarse.addPath(line) } else { fine.addPath(line) }
                x += Self.cell; i += 1
            }
            i = 0
            var y: CGFloat = 0
            while y <= size.height {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                if i % 5 == 0 { coarse.addPath(line) } else { fine.addPath(line) }
                y += Self.cell; i += 1
            }
            ctx.stroke(fine, with: .color(Theme.blueprintGrid.opacity(0.75)), lineWidth: 0.6)
            ctx.stroke(coarse, with: .color(Theme.blueprintGrid), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Tail close-up

/// The aft fuselage and fin of a type, drawn from the same `AircraftGeometry` as its side view at 2.5 times
/// the scale a side view of the same width would use, the tail cone near the right edge. The registration
/// is lettered on the aft fuselage in a monospaced font, inside a box like a placard panel (left out with
/// `showsRegistration: false`, for a faint copy behind a heading that already names it). Every layer is
/// stroked at 1 pt in `ink` (the blueprint ink by default) with no fill; the gear stays up.
public struct BlueprintTail: View {
    var type: AircraftType?
    var registration: String
    var ink: Color
    var showsRegistration: Bool
    /// The lettering's smallest size, following Dynamic Type.
    @ScaledMetric(relativeTo: .caption2) private var letterFloor: CGFloat = 11

    /// How much closer than a side view of the same width.
    public static let zoom: CGFloat = 2.5

    /// What the tail drawing strokes.
    static let drawnLayers: Set<AircraftLayer> = [.fuselage, .windows, .doors, .tail]

    public init(type: AircraftType?, registration: String, ink: Color = Theme.blueprintInk, showsRegistration: Bool = true) {
        self.type = type; self.registration = registration; self.ink = ink; self.showsRegistration = showsRegistration
    }

    /// Lettering size and placard box, in view points, for a frame of `size`: a fifth of the barrel's drawn
    /// height, never under `floor` (itself held to 8% of the frame width so it fits the drawing) nor over 5.5%
    /// of the width. The box is sized for a monospaced face (0.6 em advance) with half a letter of margin.
    static func placard(_ g: AircraftGeometry, size: CGSize, registration: String, floor: CGFloat)
        -> (letter: CGFloat, box: CGRect) {
        let t = transform(g, size: size)
        let diameter = (g.fuselageTopM - g.fuselageBottomM) * t.a
        let least = min(floor, size.width * 0.08)
        let letter = max(least, min(diameter * 0.2, size.width * 0.055))
        let centre = registrationCentre(g, size: size).applying(t)
        let textWidth = CGFloat(registration.count) * letter * 0.6
        // Held inside the frame: on a short barrel the centre can sit so far left the box would be cut.
        let width = textWidth + letter
        let x = max(centre.x - width / 2, 2)
        let box = CGRect(x: x, y: centre.y - letter * 0.95, width: width, height: letter * 1.9)
        return (letter, box)
    }

    /// Metres (x from the nose, y up from the ground) to points in a frame of `size`: `zoom` times the side
    /// view's scale, the tail end 3% in from the right edge, the barrel bottom 6% above the bottom edge (the
    /// fin top may run off the top, as on the references).
    public static func transform(_ g: AircraftGeometry, size: CGSize) -> CGAffineTransform {
        let s = zoom * size.width / g.lengthM
        let tx = size.width * 0.97 - g.lengthM * s
        let ty = size.height * 0.94 + g.fuselageBottomM * s
        return CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: tx, ty: ty)
    }

    /// Where the registration is lettered, in metres: halfway between the frame's left edge and the fin's
    /// leading edge, on the window line.
    static func registrationCentre(_ g: AircraftGeometry, size: CGSize) -> CGPoint {
        let t = transform(g, size: size)
        let leftM = -t.tx / t.a
        let finLE = g.parts[.fin]?.boundingRect.minX ?? g.finBox.minX
        let x = (max(leftM, 0) + finLE) / 2
        let band = g.cheatlineBand
        return CGPoint(x: x, y: (band.lowerBound + band.upperBound) / 2)
    }

    public var body: some View {
        let g = AircraftGeometry.geometry(type: type)
        let floor = letterFloor
        Canvas { ctx, size in
            let toView = Self.transform(g, size: size)
            if showsRegistration {
                // Lettering painted on the skin; the panel beside the drawing carries the registration as text.
                let (letter, box) = Self.placard(g, size: size, registration: registration, floor: floor)
                let placard = Path(roundedRect: box, cornerRadius: 2)
                ctx.stroke(placard, with: .color(ink), lineWidth: 1)
                ctx.draw(Text(registration).font(.system(size: letter, weight: .medium, design: .monospaced))
                    .foregroundStyle(ink), at: CGPoint(x: box.midX, y: box.midY))
                // The airframe's lines stop at the placard's edge.
                var outside = Path(CGRect(origin: .zero, size: size))
                outside.addPath(placard)
                ctx.clip(to: outside, style: FillStyle(eoFill: true))
            }
            // One path, one stroke call. Only the barrel, its windows and doors, and the tail: at this zoom
            // the wing and engines are cut by the frame's left edge into stray pieces.
            var lines = Path()
            for shape in g.shapes where Self.drawnLayers.contains(shape.layer) { lines.addPath(shape.path) }
            ctx.stroke(lines.applying(toView), with: .color(ink), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Cabin plan

/// A generic cabin seen from above with the class bar over it (Eco, Eco+, Business, First and their
/// counts), the favourite seat and three seat glyphs (aisle, middle, window) with their counts. Every count
/// comes from the store's `AircraftStats`; parts with nothing to show stay out.
public struct CabinPlan: View {
    var classes: SeatClassCounts
    var positions: PositionCounts
    /// The favourite seat's title and line, ("Favorite seat", "20D (2 times)"), from `AircraftStatsCopy`.
    var favourite: (title: String, value: String)?

    public init(classes: SeatClassCounts, positions: PositionCounts, favourite: (title: String, value: String)?) {
        self.classes = classes; self.positions = positions; self.favourite = favourite
    }

    static func hasClasses(_ c: SeatClassCounts) -> Bool {
        c.economy + c.premiumEconomy + c.business + c.first + c.private > 0
    }
    static func hasSeats(_ p: PositionCounts, hasFavourite: Bool) -> Bool {
        hasFavourite || p.aisle + p.middle + p.window > 0 || hasCockpit(p)
    }
    static func hasCockpit(_ p: PositionCounts) -> Bool { p.captain + p.pilot + p.jumpseat > 0 }

    /// "Captain 2 · Pilot 1": the cockpit seats flown, nil when none.
    static func cockpitLine(_ p: PositionCounts) -> String? {
        let parts = [("Captain", p.captain), ("Pilot", p.pilot), ("Jumpseat", p.jumpseat)]
            .filter { $0.1 > 0 }.map { "\($0.0) \(PassportFacts.count($0.1))" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The class bar turns into a row per class from this size: four or five segments of at least `cellMinimum`
    /// no longer fit a 375 pt phone.
    static func stacksClasses(_ size: DynamicTypeSize) -> Bool { size >= .xxxLarge }

    private var rows: [(String, UInt32)] {
        // Private joins the bar only once flown, so most bars keep their four segments.
        [("Eco", classes.economy), ("Eco+", classes.premiumEconomy), ("Business", classes.business), ("First", classes.first)]
            + (classes.private > 0 ? [("Private", classes.private)] : [])
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if Self.hasClasses(classes) { classBar }
            if Self.hasSeats(positions, hasFavourite: favourite != nil) { seats }
            if let cockpit = Self.cockpitLine(positions) {
                HStack(spacing: 8) {
                    Image(systemName: "airplane").scaledFont(13, weight: .semibold)
                    Text("Cockpit").scaledFont(14, weight: .semibold)
                    Text(cockpit).scaledFont(14).monospacedDigit()
                }
                .scaledPadding(.horizontal, 20)
                .accessibilityElement(children: .combine)
            }
        }
        .foregroundStyle(Theme.blueprintInk)
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var cellMinimum: CGFloat = 58
    @ScaledMetric(relativeTo: .subheadline) private var cellHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .subheadline) private var labelHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var seatSide: CGFloat = 24

    // MARK: Class bar

    /// One segment per class, wider the more it was flown; from xxxLarge a row per class instead.
    @ViewBuilder private var classBar: some View {
        if Self.stacksClasses(typeSize) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.0) { name, count in
                    HStack {
                        Text(name).scaledFont(14)
                        Spacer(minLength: 8)
                        Text(PassportFacts.count(count)).scaledFont(14, weight: .semibold).monospacedDigit()
                    }
                    .scaledPadding(.horizontal, 7)
                    .frame(minHeight: cellHeight)
                    .background(Rectangle().fill(Theme.blueprintInk.opacity(0.18)))
                    .accessibilityElement(children: .combine)
                }
            }
            .scaledPadding(.horizontal, 20)
        } else {
            segments
        }
    }

    private var segments: some View {
        let total = max(rows.reduce(0) { $0 + $1.1 }, 1)
        return GeometryReader { geo in
            let gap: CGFloat = 3
            let n = CGFloat(rows.count)
            let spare = max(geo.size.width - cellMinimum * n - gap * (n - 1), 0)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(rows, id: \.0) { name, count in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(name).scaledFont(14).lineLimit(1).minimumScaleFactor(0.7)
                        HStack {
                            Spacer(minLength: 0)
                            Text(PassportFacts.count(count)).scaledFont(14, weight: .semibold).monospacedDigit()
                                .foregroundStyle(Theme.blueprint)
                        }
                        .scaledPadding(.horizontal, 7)
                        .frame(height: cellHeight)
                        .background(Rectangle().fill(Theme.blueprintInk.opacity(0.62)))
                    }
                    .frame(width: cellMinimum + spare * CGFloat(count) / CGFloat(total))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(name), \(count)")
                }
            }
        }
        .frame(height: labelHeight + 6 + cellHeight)
        .scaledPadding(.horizontal, 20)
    }

    // MARK: Seats

    private var seats: some View {
        let stacked = typeSize.isAccessibilitySize
        // At accessibility sizes the favourite seat goes on top and the seats under it, a row each.
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            if let favourite {
                VStack(alignment: .leading, spacing: 2) {
                    Text(favourite.title).scaledFont(15, weight: .semibold)
                    Text(favourite.value).scaledFont(16)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !stacked {
                Spacer()
            }
            if stacked {
                VStack(alignment: .leading, spacing: 10) {
                    seatRow("Aisle", positions.aisle, .aisle)
                    seatRow("Middle", positions.middle, .middle)
                    seatRow("Window", positions.window, .window)
                }
            } else {
                HStack(alignment: .bottom, spacing: 14) {
                    seat("Aisle", positions.aisle, .aisle)
                    seat("Middle", positions.middle, .middle)
                    seat("Window", positions.window, .window)
                }
                Spacer(minLength: 0).frame(maxWidth: .infinity)
            }
        }
        // Inside the cabin walls: 40 pt at the reference, 24 pt at accessibility sizes so the rows keep their width.
        .scaledPadding(.horizontal, stacked ? 24 : 40)
        .scaledPadding(.vertical, 26)
        .background(CabinOutline().stroke(Theme.blueprintInk, lineWidth: 1))
        .frame(maxWidth: .infinity)
    }

    private func glyph(_ position: SeatGlyph.Position) -> some View {
        SeatGlyph(position: position)
            .stroke(Theme.blueprintInk, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            .frame(width: seatSide * 1.3, height: seatSide)
    }

    private func seat(_ name: String, _ count: UInt32, _ position: SeatGlyph.Position) -> some View {
        VStack(spacing: 3) {
            Text(PassportFacts.count(count)).scaledFont(16).monospacedDigit()
            glyph(position)
            Text(name).scaledFont(11, weight: .medium).opacity(0.85).lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(count)")
    }

    /// One seat per row at accessibility sizes: glyph, count, then the name, which may wrap.
    private func seatRow(_ name: String, _ count: UInt32, _ position: SeatGlyph.Position) -> some View {
        HStack(alignment: .center, spacing: 10) {
            glyph(position)
            Text(PassportFacts.count(count)).scaledFont(16, weight: .semibold).monospacedDigit()
            Text(name).scaledFont(14).opacity(0.85).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(count)")
    }
}

/// A seat from the front (backrest, cushion, armrests and legs) with what sits beside it: a window at the
/// right of the window seat, the neighbours' armrests either side of the middle seat, the aisle's walkway
/// at the left of the aisle seat. Drawn in a box 1.3 wide for 1 high.
struct SeatGlyph: Shape {
    enum Position { case window, middle, aisle }
    var position: Position

    func path(in rect: CGRect) -> Path {
        let h = rect.height
        let w = h * 0.78
        let x0 = rect.midX - w / 2, y0 = rect.minY
        var p = Path()
        // Backrest.
        p.addRoundedRect(in: CGRect(x: x0 + w * 0.18, y: y0, width: w * 0.64, height: h * 0.62),
                         cornerSize: CGSize(width: w * 0.16, height: w * 0.16))
        // Cushion.
        p.addRoundedRect(in: CGRect(x: x0 + w * 0.12, y: y0 + h * 0.56, width: w * 0.76, height: h * 0.18),
                         cornerSize: CGSize(width: h * 0.06, height: h * 0.06))
        // Armrests.
        for x in [x0, x0 + w * 0.88] {
            p.addRoundedRect(in: CGRect(x: x, y: y0 + h * 0.36, width: w * 0.12, height: h * 0.34),
                             cornerSize: CGSize(width: w * 0.05, height: w * 0.05))
        }
        // Legs.
        for x in [x0 + w * 0.26, x0 + w * 0.74] {
            p.move(to: CGPoint(x: x, y: y0 + h * 0.74)); p.addLine(to: CGPoint(x: x, y: y0 + h * 0.95))
        }
        let side = (rect.width - w) / 2
        switch position {
        case .window:
            p.addRoundedRect(in: CGRect(x: x0 + w + side * 0.35, y: y0 + h * 0.1, width: side * 0.45, height: h * 0.4),
                             cornerSize: CGSize(width: side * 0.2, height: side * 0.2))
        case .middle:
            for x in [x0 - side * 0.55, x0 + w + side * 0.25] {
                p.move(to: CGPoint(x: x + side * 0.15, y: y0 + h * 0.2)); p.addLine(to: CGPoint(x: x + side * 0.15, y: y0 + h * 0.8))
            }
        case .aisle:
            let x = x0 - side * 0.5
            var y = y0 + h * 0.05
            while y < y0 + h * 0.95 {
                p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: min(y + h * 0.12, y0 + h * 0.95)))
                y += h * 0.22
            }
        }
        return p
    }
}

/// A generic narrow cabin from above, open at the left, the nose at the right: the two side walls with a
/// window row along each, exit doors breaking the rows, and the cockpit bulkhead and windscreen in the nose.
/// The same plan for every type (a 777 and an A220 look alike): `AircraftGeometry` has no top view, and the
/// counts it frames are across all types anyway.
struct CabinOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let noseStart = rect.minX + w * 0.8
        let top = rect.minY + 1, bottom = rect.maxY - 1, mid = rect.midY
        // Walls and nose.
        p.move(to: CGPoint(x: rect.minX, y: top))
        p.addLine(to: CGPoint(x: noseStart, y: top))
        p.addCurve(to: CGPoint(x: rect.maxX - 2, y: mid),
                   control1: CGPoint(x: noseStart + w * 0.12, y: top), control2: CGPoint(x: rect.maxX - 2, y: mid - h * 0.25))
        p.addCurve(to: CGPoint(x: noseStart, y: bottom),
                   control1: CGPoint(x: rect.maxX - 2, y: mid + h * 0.25), control2: CGPoint(x: noseStart + w * 0.12, y: bottom))
        p.addLine(to: CGPoint(x: rect.minX, y: bottom))
        // Cockpit bulkhead and windscreen.
        let b = noseStart + w * 0.005
        p.move(to: CGPoint(x: b, y: top + h * 0.08))
        p.addQuadCurve(to: CGPoint(x: b, y: bottom - h * 0.08), control: CGPoint(x: b + w * 0.09, y: mid))
        p.move(to: CGPoint(x: b + w * 0.02, y: top + h * 0.12))
        p.addQuadCurve(to: CGPoint(x: b + w * 0.02, y: bottom - h * 0.12), control: CGPoint(x: b + w * 0.1, y: mid))
        // Window rows with exits: windows every 2.6% of the width, a door every 34%.
        let windowW = w * 0.011, windowH = max(2.5, h * 0.035)
        for row in [top + h * 0.05, bottom - h * 0.05 - windowH] {
            var x = rect.minX + w * 0.02
            var i = 0
            while x < noseStart - w * 0.03 {
                if i % 13 == 9 {
                    // Exit door: a bracket set into the wall.
                    let edge = row < mid ? top : bottom
                    let depth = row < mid ? h * 0.07 : -h * 0.07
                    p.move(to: CGPoint(x: x, y: edge))
                    p.addLine(to: CGPoint(x: x, y: edge + depth))
                    p.addLine(to: CGPoint(x: x + w * 0.04, y: edge + depth))
                    p.addLine(to: CGPoint(x: x + w * 0.04, y: edge))
                    x += w * 0.055
                } else {
                    p.addRoundedRect(in: CGRect(x: x, y: row, width: windowW, height: windowH),
                                     cornerSize: CGSize(width: windowH * 0.4, height: windowH * 0.4))
                    x += w * 0.026
                }
                i += 1
            }
        }
        return p
    }
}

#if DEBUG
#Preview("Blueprint") {
    BlueprintPanel {
        VStack(spacing: 20) {
            BlueprintTail(type: nil, registration: "F-GSQI").aspectRatio(1.8, contentMode: .fit)
            AircraftSideView(type: nil, style: .blueprint).frame(height: 60)
            CabinPlan(classes: SeatClassCounts(economy: 54, premiumEconomy: 0, business: 2, first: 0, private: 0),
                      positions: PositionCounts(window: 5, middle: 6, aisle: 24, pilot: 0, captain: 0, jumpseat: 0), favourite: ("Favorite seat", "20D (2 times)"))
        }
        .padding(.vertical)
    }
}
#endif
