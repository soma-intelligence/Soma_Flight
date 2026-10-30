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

    @Test func blueprintHasNoFill() throws {
        let type = ReferenceData.bundled().type("B77W")
        let g = AircraftGeometry.geometry(type: type)
        let width: CGFloat = 400
        let bitmap = try #require(Bitmap(AircraftSideView(type: type, style: .blueprint)
            .frame(width: width)
            .background(Theme.blueprint)))
        let height = width / AircraftSideView.aspect(type: type)
        #expect(bitmap.width == Int(width) && abs(CGFloat(bitmap.height) - height) <= 1)
        // The canvas maps metres the way AircraftCanvas does: x * s, (heightM - y) * s.
        let s = width / g.lengthM
        let toView = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: 0, ty: g.heightM * s)
        let hull = try #require(g.parts[.hull]).applying(toView)
        // Every other part with a 3 pt margin around it: small parts (windows, door handles) by their box, as
        // the stroked outline of a part narrower than the margin winds to nothing around its middle; larger
        // ones by their outline and interior.
        let others = g.shapes.filter { $0.layer != .gear && $0.layer != .gearFar && $0.part != .hull }
            .map { $0.path.applying(toView) }
        let boxes = others.map { $0.boundingRect.insetBy(dx: -3, dy: -3) }.filter { $0.width < 12 || $0.height < 12 }
        let large = others.filter { let b = $0.boundingRect; return b.width >= 6 && b.height >= 6 }
        let outlines = large.map { $0.strokedPath(StrokeStyle(lineWidth: 6)) } + large + [hull.strokedPath(StrokeStyle(lineWidth: 6))]
        func clear(_ pt: CGPoint) -> Bool {
            !boxes.contains { $0.contains(pt) } && !outlines.contains { $0.contains(pt) }
        }
        // Points inside the hull, clear of every line by 3 pt and outside every other part.
        var interior: [CGPoint] = []
        for y in stride(from: 1, to: Int(height) - 2, by: 2) {
            for x in stride(from: 1, to: Int(width) - 1, by: 3) {
                let pt = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                if hull.contains(pt) && clear(pt) { interior.append(pt) }
            }
        }
        #expect(interior.count > 20, "found \(interior.count) clear interior points")
        for pt in interior {
            let c = bitmap.rgb(Int(pt.x), Int(pt.y))
            #expect(Self.close(c, Self.panel), "fill at \(pt): \(c)")
        }
        // The lines are drawn, in the light ink.
        #expect(bitmap.count(differingFrom: Self.panel) > 500)
    }

    @Test func tailUsesSameGeometry() {
        let size = CGSize(width: 360, height: 200)
        for family in [AircraftFamily.a320, .b777, .b787, .other] {
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
        let plan = try #require(Bitmap(CabinPlan(classes: SeatClassCounts(economy: 22, premiumEconomy: 4, business: 3, first: 4),
                                                 positions: PositionCounts(window: 17, middle: 1, aisle: 20),
                                                 favourite: "12A (1 time)")
            .frame(width: 393).background(Theme.blueprint)))
        #expect(plan.count(differingFrom: Self.panel) > 1000)
        // Nothing to show: no class bar, no seats.
        let empty = SeatClassCounts(economy: 0, premiumEconomy: 0, business: 0, first: 0)
        #expect(!CabinPlan.hasClasses(empty))
        #expect(!CabinPlan.hasSeats(PositionCounts(window: 0, middle: 0, aisle: 0), favourite: nil))
        #expect(CabinPlan.hasSeats(PositionCounts(window: 0, middle: 0, aisle: 0), favourite: "1A (1 time)"))
    }
}
