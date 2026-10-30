import CoreGraphics
import SwiftUI
import Testing
@testable import FlightKit

/// The side-view geometry: every drawn family keeps the proportions of the real aircraft (overall
/// length over overall height, from the manufacturers' airport planning documents), carries every
/// layer a livery paints, and anything we have no drawing for falls back to a generic airliner.
struct AircraftGeometryTests {
    /// Overall length and height in metres of the variant each family draws by default.
    static let dimensions: [(AircraftFamily, length: Double, height: Double)] = [
        (.a320, 37.57, 11.76),     // A320
        (.a350, 66.80, 17.05),     // A350-900
        (.b737, 39.47, 12.55),     // 737-800
        (.b737max, 39.52, 12.29),  // 737 MAX 8
        (.b777, 73.86, 18.50),     // 777-300ER
        (.b787, 62.81, 17.02),     // 787-9
        (.a220, 38.71, 11.51),     // A220-300
        (.a330, 63.69, 16.79),     // A330-300
        (.a380, 72.72, 24.09),     // A380-800
        (.b747, 70.66, 19.41),     // 747-400
        (.b757, 47.32, 13.56),     // 757-200
        (.b767, 54.94, 15.85),     // 767-300
        (.ejet, 36.24, 10.57),     // E190
        (.crj, 36.40, 7.51),       // CRJ900
        (.atr, 27.17, 7.65),       // ATR 72-600
    ]

    static func type(_ id: String, _ family: AircraftFamily) -> AircraftType {
        AircraftType(id: id, family: family, manufacturer: "", name: id)
    }

    static func drawnBounds(_ g: AircraftGeometry) -> CGRect {
        g.layers.values.flatMap { $0 }.reduce(CGRect.null) { $0.union($1.boundingRect) }
    }

    @Test func aspectMatchesDimensions() {
        for (family, length, height) in Self.dimensions {
            let g = AircraftGeometry.geometry(family)
            #expect(g.family == family)
            let box = Self.drawnBounds(g)
            let expected = length / height
            let drawn = box.width / box.height
            #expect(abs(drawn - expected) / expected < 0.03, "\(family): drawn \(drawn), expected \(expected)")
            #expect(abs(g.lengthM - length) < 0.01 && abs(g.heightM - height) < 0.01, "\(family) table")
            // Nose at x = 0, wheels on the ground.
            #expect(abs(box.minX) < 0.05 && abs(box.minY) < 0.05, "\(family) origin \(box.origin)")
        }
    }

    @Test func everyLayerPresent() {
        let needed: [AircraftLayer] = [.fuselage, .windows, .doors, .wing, .engine, .engineFar, .tail, .gear]
        #expect(Set(Self.dimensions.map { $0.0 }) == Set(AircraftFamily.allCases).subtracting([.other]))
        for (family, _, _) in Self.dimensions {
            let g = AircraftGeometry.geometry(family)
            for layer in needed {
                #expect(!(g.layers[layer] ?? []).isEmpty, "\(family) misses \(layer)")
            }
            // Livery parts each have their own path.
            for part in [AircraftPart.hull, .fin, .nacelle, .window, .door, .tyre] {
                #expect(g.parts[part] != nil, "\(family) misses part \(part)")
            }
            #expect(g.finBox.width > 0 && g.finBox.height > 0)
            #expect(g.finBox.maxY <= g.heightM && g.finBox.maxX <= g.lengthM)
            #expect(g.cheatlineBand.lowerBound > g.fuselageBottomM && g.cheatlineBand.upperBound < g.fuselageTopM)
        }
    }

    @Test func unknownTypeFallsBackToGeneric() {
        let none = AircraftGeometry.geometry(type: nil)
        #expect(none.lengthM == Generic.narrowbody.lengthM && none.family == Generic.narrowbody.family)
        let odd = AircraftType(id: "ZZZZ", family: .other, manufacturer: "Nobody", name: "Unknown")
        #expect(AircraftGeometry.geometry(type: odd).lengthM == Generic.narrowbody.lengthM)
        // Every named family has its own drawing now; only `.other` takes the generic body.
        #expect(AircraftGeometry.geometry(.other).lengthM == Generic.narrowbody.lengthM)
        let a340 = AircraftType(id: "A346", family: .other, manufacturer: "Airbus", name: "A340-600")
        #expect(AircraftGeometry.geometry(type: a340).family == .other)
        #expect(AircraftGeometry.geometry(.a330).lengthM != Generic.widebody.lengthM)
        #expect(AircraftGeometry.geometry(.crj).lengthM != Generic.narrowbody.lengthM)
        // An unknown variant inside a drawn family takes the family's default.
        let a320ish = AircraftType(id: "A3XX", family: .a320, manufacturer: "Airbus", name: "A320 something")
        #expect(AircraftGeometry.geometry(type: a320ish).lengthM == AircraftGeometry.geometry(.a320).lengthM)
    }

    @Test func a321LongerThanA319() {
        func type(_ id: String) -> AircraftType { AircraftType(id: id, family: .a320, manufacturer: "Airbus", name: id) }
        let a319 = AircraftGeometry.geometry(type: type("A319"))
        let a320 = AircraftGeometry.geometry(type: type("A320"))
        let a321 = AircraftGeometry.geometry(type: type("A21N"))
        #expect(a319.lengthM < a320.lengthM && a320.lengthM < a321.lengthM)
        #expect(abs(a321.lengthM - 44.51) < 0.01 && abs(a319.lengthM - 33.84) < 0.01)
        #expect(Self.drawnBounds(a321).width > Self.drawnBounds(a319).width + 10)
        // The stretch adds windows and the A321 gets its extra door pair.
        #expect((a321.layers[.windows]?.count ?? 0) > (a319.layers[.windows]?.count ?? 0))
        #expect((a321.layers[.doors]?.count ?? 0) > (a319.layers[.doors]?.count ?? 0))
    }

    @Test func variantsUseTheirOwnLength() {
        func type(_ id: String, _ f: AircraftFamily) -> AircraftType { AircraftType(id: id, family: f, manufacturer: "", name: id) }
        #expect(abs(AircraftGeometry.geometry(type: type("B772", .b777)).lengthM - 63.73) < 0.01)
        #expect(abs(AircraftGeometry.geometry(type: type("B78X", .b787)).lengthM - 68.28) < 0.01)
        #expect(abs(AircraftGeometry.geometry(type: type("A35K", .a350)).lengthM - 73.79) < 0.01)
        #expect(abs(AircraftGeometry.geometry(type: type("B39M", .b737max)).lengthM - 42.16) < 0.01)
        let lengths: [(String, AircraftFamily, Double)] = [
            ("BCS1", .a220, 35.00), ("A332", .a330, 58.82), ("A339", .a330, 63.66), ("B748", .b747, 76.25),
            ("B74S", .b747, 56.31), ("B753", .b757, 54.47), ("B762", .b767, 48.51), ("B764", .b767, 61.37),
            ("E170", .ejet, 29.90), ("E295", .ejet, 41.51), ("CRJ2", .crj, 26.77), ("CRJX", .crj, 39.13),
            ("AT45", .atr, 22.67),
        ]
        for (id, family, length) in lengths {
            let g = AircraftGeometry.geometry(type: type(id, family))
            #expect(abs(g.lengthM - length) < 0.01, "\(id) \(g.lengthM)")
            #expect(abs(Self.drawnBounds(g).width - length) < 0.1, "\(id) drawn \(Self.drawnBounds(g).width)")
        }
    }

    /// The CRJ hangs its engines on the aft fuselage, above the barrel's middle and behind the wing, and
    /// carries its tailplane on top of the fin; an underwing twin is the opposite.
    @Test func crjHasRearEngines() throws {
        for id in ["CRJ2", "CRJ7", "CRJ9", "CRJX"] {
            let g = AircraftGeometry.geometry(type: Self.type(id, .crj))
            let nacelles = g.shapes.filter { $0.layer == .engine && $0.part == .nacelle }.map { $0.path.boundingRect }
            #expect(nacelles.count == 1, "\(id) near nacelles \(nacelles.count)")
            let wing = try #require(g.shapes.first { $0.layer == .wing && $0.part == .wing }).path.boundingRect
            let middle = (g.fuselageBottomM + g.fuselageTopM) / 2
            for n in nacelles {
                #expect(n.midX > g.lengthM * 0.6, "\(id) nacelle at \(n.midX)")
                #expect(n.midY > middle, "\(id) nacelle below the barrel's middle")
                #expect(n.minX > wing.midX, "\(id) nacelle ahead of the wing")
            }
            let fin = try #require(g.parts[.fin]).boundingRect
            let tailplane = try #require(g.parts[.tailplane]).boundingRect
            #expect(tailplane.minY > fin.midY && tailplane.maxY >= fin.maxY, "\(id) not a T-tail")
        }
        let a320 = AircraftGeometry.geometry(.a320)
        let under = a320.shapes.filter { $0.layer == .engine && $0.part == .nacelle }.map { $0.path.boundingRect }
        #expect(under.allSatisfy { $0.midX < a320.lengthM * 0.5 && $0.midY < a320.fuselageBottomM + 0.5 })
    }

    /// Four engines on the A380 and 747 (two a side), propellers on the ATR, a second deck of windows on the
    /// A380 and the 747's hump.
    @Test func engineLayouts() {
        func near(_ g: AircraftGeometry, _ part: AircraftPart) -> Int {
            g.shapes.filter { $0.layer == .engine && $0.part == part }.count
        }
        for family in [AircraftFamily.a380, .b747] {
            let g = AircraftGeometry.geometry(family)
            #expect(near(g, .nacelle) == 2, "\(family)")
            #expect(g.shapes.filter { $0.layer == .engineFar && $0.part == .nacelle }.count == 2, "\(family) far")
            // The upper deck: windows well above the main deck's cheatline band.
            let high = g.shapes.filter { $0.part == .window && $0.path.boundingRect.minY > g.cheatlineBand.upperBound + 1 }
            #expect(high.count > 8, "\(family) upper deck windows \(high.count)")
        }
        let atr = AircraftGeometry.geometry(.atr)
        #expect(near(atr, .nacelle) == 1 && near(atr, .propeller) >= 2 && near(atr, .spinner) == 1)
        #expect(near(AircraftGeometry.geometry(.a330), .propeller) == 0)
        // The 747's hump rises above the barrel; the A380's double deck does not need one.
        let b747 = AircraftGeometry.geometry(.b747)
        let hull = b747.parts[.hull]!.boundingRect
        #expect(hull.maxY > b747.fuselageTopM + 1)
        // High wing: the ATR's wing sits on the crown.
        let wing = atr.shapes.first { $0.layer == .wing && $0.part == .wing }!.path.boundingRect
        #expect(wing.midY > atr.fuselageTopM - 0.5)
    }

    @Test func everyPathInsideTheBox() {
        for family in AircraftFamily.allCases {
            let g = AircraftGeometry.geometry(family)
            let box = Self.drawnBounds(g)
            #expect(box.minX >= -0.05 && box.maxX <= g.lengthM + 0.05, "\(family) x \(box)")
            #expect(box.minY >= -0.05 && box.maxY <= g.heightM + 0.05, "\(family) y \(box)")
        }
    }
}
