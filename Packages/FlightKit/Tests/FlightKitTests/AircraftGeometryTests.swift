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
    ]

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
        let needed: [AircraftLayer] = [.fuselage, .windows, .doors, .wing, .engine, .tail, .gear]
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
        // A family without its own drawing yet takes the generic body of its size.
        #expect(AircraftGeometry.geometry(.a330).lengthM == Generic.widebody.lengthM)
        #expect(AircraftGeometry.geometry(.crj).lengthM == Generic.narrowbody.lengthM)
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
