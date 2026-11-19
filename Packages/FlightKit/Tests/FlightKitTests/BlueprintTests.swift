import CoreGraphics
import SwiftUI
import Testing
import FlightCore
@testable import FlightKit

/// The blueprint line style: line art with no fill, the tail close-up drawn from the side view's own
/// geometry, and drawings for any type, known or not.
@MainActor
struct BlueprintTests {
    /// RGBA bytes of a rendered view at 1x, top row first.
    struct Bitmap {
        var width: Int
        var height: Int
        var bytes: [UInt8]

        @MainActor init?<V: View>(_ view: V) {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let cg = renderer.cgImage else { return nil }
            width = cg.width; height = cg.height
            var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let ok = data.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                          bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                return true
            }
            guard ok else { return nil }
            bytes = data
        }

        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }

        /// Pixels further than `tolerance` from `colour` in any channel.
        func count(differingFrom colour: (Int, Int, Int), tolerance: Int = 6) -> Int {
            var n = 0
            for y in 0..<height {
                for x in 0..<width {
                    let c = rgb(x, y)
                    if abs(c.0 - colour.0) > tolerance || abs(c.1 - colour.1) > tolerance || abs(c.2 - colour.2) > tolerance { n += 1 }
                }
            }
            return n
        }
    }

    /// Theme.blueprint as bytes (0x2F6BBA).
    static let panel = (0x2F, 0x6B, 0xBA)

    static func close(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ tolerance: Int = 6) -> Bool {
        abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
    }

    /// Points of the hull, mapped by `toView` into a `width` by `height` frame, clear of every line by 3 pt and
    /// outside every other part (and outside `avoid`). Small parts (windows, door handles) are kept off by their
    /// box: the stroked outline of a part narrower than the margin winds to nothing around its middle.
    static func clearHullPoints(_ g: AircraftGeometry, _ toView: CGAffineTransform, width: CGFloat, height: CGFloat,
                                avoid: CGRect = .null) throws -> [CGPoint] {
        let hull = try #require(g.parts[.hull]).applying(toView)
        let others = g.shapes.filter { $0.layer != .gear && $0.layer != .gearFar && $0.part != .hull }
            .map { $0.path.applying(toView) }
        let boxes = others.map { $0.boundingRect.insetBy(dx: -3, dy: -3) }.filter { $0.width < 12 || $0.height < 12 }
            + [avoid.insetBy(dx: -3, dy: -3)]
        let large = others.filter { let b = $0.boundingRect; return b.width >= 6 && b.height >= 6 }
        let outlines = large.map { $0.strokedPath(StrokeStyle(lineWidth: 6)) } + large + [hull.strokedPath(StrokeStyle(lineWidth: 6))]
        var points: [CGPoint] = []
        for y in stride(from: 1, to: Int(height) - 2, by: 2) {
            for x in stride(from: 1, to: Int(width) - 1, by: 3) {
                let pt = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                if hull.contains(pt) && !boxes.contains(where: { $0.contains(pt) }) && !outlines.contains(where: { $0.contains(pt) }) {
                    points.append(pt)
                }
            }
        }
        return points
    }

    func expectPanel(_ bitmap: Bitmap, at points: [CGPoint], _ what: String) {
        #expect(points.count > 20, "\(what): found \(points.count) clear interior points")
        for pt in points {
            let c = bitmap.rgb(Int(pt.x), Int(pt.y))
            #expect(Self.close(c, Self.panel), "\(what) fill at \(pt): \(c)")
        }
    }

    @Test func blueprintHasNoFill() throws {
        let reference = ReferenceData.bundled()
        // Side view: the canvas maps metres the way AircraftCanvas does, x * s and (heightM - y) * s.
        let type = reference.type("B77W")
        let g = AircraftGeometry.geometry(type: type)
        let width: CGFloat = 400
        let side = try #require(Bitmap(AircraftSideView(type: type, style: .blueprint)
            .frame(width: width)
            .background(Theme.blueprint)))
        let height = width / AircraftSideView.aspect(type: type)
        #expect(side.width == Int(width) && abs(CGFloat(side.height) - height) <= 1)
        let s = width / g.lengthM
        let toView = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: 0, ty: g.heightM * s)
        expectPanel(side, at: try Self.clearHullPoints(g, toView, width: width, height: height), "side view")
        #expect(side.count(differingFrom: Self.panel) > 500)

        // Tail close-up, with and without the placard (whose lettering is ink, so its box is kept off).
        let size = CGSize(width: 360, height: 200)
        for id in ["B77W", "A320"] {
            let t = reference.type(id)
            let tg = AircraftGeometry.geometry(type: t)
            let toTail = BlueprintTail.transform(tg, size: size)
            let box = BlueprintTail.placard(tg, size: size, registration: "N370DN", floor: 11).box
            // Checked against what the close-up strokes (its tailplane narrowed clear of the cabin), hull included.
            var drawn = tg
            let lines = BlueprintTail.drawing(tg, size: size)
            drawn.shapes = lines.behind + lines.front
            for shows in [false, true] {
                let tail = try #require(Bitmap(BlueprintTail(type: t, registration: "N370DN", showsRegistration: shows)
                    .frame(width: size.width, height: size.height).background(Theme.blueprint)))
                expectPanel(tail, at: try Self.clearHullPoints(drawn, toTail, width: size.width, height: size.height, avoid: box),
                            "\(id) tail")
                #expect(tail.count(differingFrom: Self.panel) > 500)
            }
        }

        // Cabin plan: the outline's middle band and a seat's backrest stay paper.
        let cabin = try #require(Bitmap(CabinOutline().stroke(Theme.blueprintInk, lineWidth: 1)
            .frame(width: 360, height: 110).background(Theme.blueprint)))
        #expect(cabin.count(differingFrom: Self.panel) > 200)
        for y in stride(from: 33, to: 77, by: 3) {
            for x in stride(from: 36, to: 270, by: 3) {
                let c = cabin.rgb(x, y)
                #expect(Self.close(c, Self.panel), "cabin fill at \(x), \(y): \(c)")
            }
        }
        for position in [SeatGlyph.Position.aisle, .middle, .window] {
            let seat = try #require(Bitmap(SeatGlyph(position: position).stroke(Theme.blueprintInk, lineWidth: 1.2)
                .frame(width: 39, height: 30).background(Theme.blueprint)))
            #expect(seat.count(differingFrom: Self.panel) > 40)
            // Backrest centre: x 19.5, y 0.31 of the height.
            #expect(Self.close(seat.rgb(19, 9), Self.panel), "\(position) seat filled")
        }
    }

    /// The registration placard cuts the airframe's lines: inside its box only the lettering is drawn. A blank
    /// registration gives the box with nothing in it, where the lines would otherwise cross.
    @Test func placardInterruptsLines() throws {
        let size = CGSize(width: 360, height: 200)
        let blank = "      "
        for id in ["B77W", "A320", "B789"] {
            let t = ReferenceData.bundled().type(id)
            let g = AircraftGeometry.geometry(type: t)
            let (letter, box) = BlueprintTail.placard(g, size: size, registration: blank, floor: 11)
            #expect(letter >= 11, "\(id) letter \(letter)")
            let inner = box.insetBy(dx: 2.5, dy: 2.5)
            func inkInside(_ shows: Bool) throws -> Int {
                let bitmap = try #require(Bitmap(BlueprintTail(type: t, registration: blank, showsRegistration: shows)
                    .frame(width: size.width, height: size.height).background(Theme.blueprint)))
                var n = 0
                for y in Int(inner.minY.rounded(.up))..<Int(inner.maxY) {
                    for x in Int(inner.minX.rounded(.up))..<Int(inner.maxX) where !Self.close(bitmap.rgb(x, y), Self.panel) { n += 1 }
                }
                return n
            }
            #expect(try inkInside(false) > 0, "\(id): no line crosses the placard's place")
            #expect(try inkInside(true) == 0, "\(id): lines cross the placard")
        }
    }

    /// The tail close-up reads as a clean drawing: the low tailplane starts aft of every window and door at its
    /// height, nothing is cut by the frame's left edge or the placard, no APU tick or barrel joint is stroked, and
    /// the tailplane is one outline.
    @Test func tailDrawingIsClean() throws {
        let reference = ReferenceData.bundled()
        let types = AircraftFamily.allCases.map { AircraftType(id: "", family: $0, manufacturer: "", name: $0.rawValue) }
            + ["A320", "A321", "B738", "B38M", "B77W", "A359", "E190", "BCS3", "B789", "A333", "B744", "A388", "B752", "CRJ9", "AT76"]
                .map { reference.type($0) }
        let cabin = BlueprintTail.cabinParts
        for type in types {
            let g = AircraftGeometry.geometry(type: type)
            let name = type?.id.isEmpty == false ? type!.id : type?.name ?? "nil"
            for (size, fits, shows) in [(CGSize(width: 374, height: 208), true, false), (CGSize(width: 360, height: 200), false, true)] {
                let t = BlueprintTail.transform(g, size: size, fitsFin: fits)
                let box = shows ? BlueprintTail.placard(g, size: size, registration: "N370DN", floor: 11, fitsFin: fits).box : .null
                let (behind, front) = BlueprintTail.drawing(g, size: size, fitsFin: fits, avoid: box)
                #expect(!behind.contains { $0.part == .apu }, "\(name): APU drawn")
                #expect(!behind.contains { $0.layer == .doors && $0.part == .panelLine }, "\(name): barrel joint drawn")
                #expect(front.filter { $0.part == .tailplane }.count == 1, "\(name): tailplane outlines")
                let leftM = -t.tx / t.a
                for shape in behind where cabin.contains(shape.part) {
                    let b = shape.path.boundingRect
                    #expect(b.minX >= leftM, "\(name): \(shape.part) cut by the frame edge")
                    if shows { #expect(!b.applying(t).intersects(box), "\(name): \(shape.part) under the placard") }
                }
                let tp = try #require(front.first { $0.part == .tailplane }).path.boundingRect
                guard tp.minY < g.fuselageTopM else { continue }
                for shape in behind where cabin.contains(shape.part) {
                    let b = shape.path.boundingRect
                    if b.maxY >= tp.minY && b.minY <= tp.maxY {
                        #expect(b.maxX < tp.minX, "\(name): \(shape.part) at \(b.minX) under the tailplane from \(tp.minX)")
                    }
                }
            }
        }
    }

    /// Lines behind the near tailplane (hull outline, fin, doors) are hidden: inside its outline only the elevator
    /// line is stroked.
    @Test func tailplaneHidesLinesBehind() throws {
        let size = CGSize(width: 374, height: 208)
        for id in ["B738", "B77W", "A388", "CRJ9"] {
            let type = ReferenceData.bundled().type(id)
            let g = AircraftGeometry.geometry(type: type)
            let t = BlueprintTail.transform(g, size: size, fitsFin: true)
            let front = BlueprintTail.drawing(g, size: size, fitsFin: true).front.map { $0.path.applying(t) }
            let outline = try #require(front.first)
            let bitmap = try #require(Bitmap(BlueprintTail(type: type, registration: "N370DN", showsRegistration: false, fitsFin: true)
                .frame(width: size.width, height: size.height).background(Theme.blueprint)))
            let strokes = front.map { $0.strokedPath(StrokeStyle(lineWidth: 5)) }
            var checked = 0
            for y in Int(outline.boundingRect.minY)..<Int(outline.boundingRect.maxY) {
                for x in Int(outline.boundingRect.minX)..<Int(outline.boundingRect.maxX) {
                    let pt = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                    guard outline.contains(pt), !strokes.contains(where: { $0.contains(pt) }) else { continue }
                    checked += 1
                    #expect(Self.close(bitmap.rgb(x, y), Self.panel), "\(id): line behind the tailplane at \(pt)")
                }
            }
            #expect(checked > 10, "\(id): \(checked) points inside the tailplane")
        }
    }

    @Test func classBarStacksFromXXXLarge() {
        #expect(!CabinPlan.stacksClasses(.large))
        #expect(!CabinPlan.stacksClasses(.xxLarge))
        #expect(CabinPlan.stacksClasses(.xxxLarge))
        #expect(CabinPlan.stacksClasses(.accessibility5))
    }

    @Test func tailUsesSameGeometry() {
        let size = CGSize(width: 360, height: 200)
        for family in AircraftFamily.allCases {
            let g = AircraftGeometry.geometry(family)
            let t = BlueprintTail.transform(g, size: size)
            let side = size.width / g.lengthM
            let fin = g.finBox.applying(t)
            #expect(abs(fin.width - g.finBox.width * side * 2.5) < 0.001, "\(family) fin width")
            #expect(abs(fin.height - g.finBox.height * side * 2.5) < 0.001, "\(family) fin height")
            // The tail end sits in the frame, the fin's leading edge too.
            let tailEnd = CGPoint(x: g.lengthM, y: g.fuselageTopM).applying(t)
            #expect(tailEnd.x > size.width * 0.9 && tailEnd.x <= size.width, "\(family) tail end \(tailEnd.x)")
            #expect(fin.minX > 0 && fin.minX < size.width, "\(family) fin \(fin)")
            // The registration goes on the fuselage, in the frame.
            let centre = BlueprintTail.registrationCentre(g, size: size)
            #expect(centre.y > g.fuselageBottomM && centre.y < g.fuselageTopM)
            let inView = centre.applying(t)
            #expect(inView.x > 0 && inView.x < size.width && inView.y > 0 && inView.y < size.height, "\(family) \(inView)")
        }
    }

    @Test func unknownFamilyBlueprint() throws {
        let odd = AircraftType(id: "ZZZZ", family: .other, manufacturer: "Nobody", name: "Unknown")
        for type in [odd, nil] as [AircraftType?] {
            let tail = try #require(Bitmap(BlueprintTail(type: type, registration: "N370DN")
                .frame(width: 360, height: 200).background(Theme.blueprint)))
            #expect(tail.count(differingFrom: Self.panel) > 500)
            let side = try #require(Bitmap(AircraftSideView(type: type, style: .blueprint)
                .frame(width: 300).background(Theme.blueprint)))
            #expect(side.count(differingFrom: Self.panel) > 300)
        }
        let plan = try #require(Bitmap(CabinPlan(classes: SeatClassCounts(economy: 22, premiumEconomy: 4, business: 3, first: 4, private: 0),
                                                 positions: PositionCounts(window: 17, middle: 1, aisle: 20, pilot: 0, captain: 0, jumpseat: 0),
                                                 favourite: ("Favorite seat", "12A (1 time)"))
            .frame(width: 393).background(Theme.blueprint)))
        #expect(plan.count(differingFrom: Self.panel) > 1000)
        // Nothing to show: no class bar, no seats.
        let empty = SeatClassCounts(economy: 0, premiumEconomy: 0, business: 0, first: 0, private: 0)
        #expect(!CabinPlan.hasClasses(empty))
        #expect(!CabinPlan.hasSeats(PositionCounts(window: 0, middle: 0, aisle: 0, pilot: 0, captain: 0, jumpseat: 0), hasFavourite: false))
        #expect(CabinPlan.hasSeats(PositionCounts(window: 0, middle: 0, aisle: 0, pilot: 0, captain: 0, jumpseat: 0), hasFavourite: true))
    }
}
