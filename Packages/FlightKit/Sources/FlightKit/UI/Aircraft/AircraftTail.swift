import SwiftUI

/// The tail end of an aircraft's side view: the rear fuselage and the fin, cut just aft of the wing (and of
/// wing-mounted engines) so no wing shows, on a transparent ground. Cut from the same picture
/// `AircraftImage` shows: the provider side view when there is one, else its bundled stand-in.
struct TailSection: @unchecked Sendable {
    // CGImage is immutable; it only crosses actors here.
    var image: CGImage
    /// The fuselage at the cut (the image's left edge), top and bottom, in pixels from the image top.
    var barrelTop: CGFloat
    var barrelBottom: CGFloat

    var width: CGFloat { CGFloat(image.width) }
    var height: CGFloat { CGFloat(image.height) }
    var barrelMid: CGFloat { (barrelTop + barrelBottom) / 2 }
    var barrel: CGFloat { max(1, barrelBottom - barrelTop) }

    /// Where the tail section starts, as a fraction of the nose-to-tail length: just aft of the wing, its
    /// flap fairings and winglets, and of engines hung under the wing. Engines on the aft fuselage (CRJ)
    /// stay: they are part of the tail.
    static func start(type: AircraftType?) -> CGFloat {
        let g = AircraftGeometry.geometry(type: type)
        let length = g.lengthM
        guard length > 0 else { return 0.62 }
        var aft = 0.0
        for shape in g.shapes {
            let box = shape.path.boundingRect
            guard !box.isNull, box.width.isFinite else { continue }
            switch shape.part {
            case .wing, .flapFairing, .winglet:
                aft = max(aft, box.maxX)
            case .nacelle, .pylon, .inlet, .fan, .exhaust, .plug, .propeller, .spinner:
                if box.maxX < length * 0.7 { aft = max(aft, box.maxX) }
            default:
                break
            }
        }
        // A provider's picture is not our drawing to the metre: keep a margin behind the wing.
        return min(max(aft / length + 0.05, 0.55), 0.78)
    }

    /// The section of `full` (nose left, nose tip at x = 0, tail tip at the right edge) from `start` of
    /// its width aft, cut to its pixels; nil when nothing is left.
    static func cut(_ full: CGImage, start: CGFloat) -> TailSection? {
        let w = full.width, h = full.height
        let x0 = min(max(0, Int((CGFloat(w) * start).rounded())), w - 2)
        let cw = w - x0
        guard cw > 1, h > 1, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var alpha = [UInt8](repeating: 0, count: cw * h * 4)
        let drawn: Bool = alpha.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: cw, height: h, bitsPerComponent: 8,
                                      bytesPerRow: cw * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(full, in: CGRect(x: -x0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        func a(_ x: Int, _ y: Int) -> UInt8 { alpha[(y * cw + x) * 4 + 3] }
        // A picture is not our drawing to the metre: a winglet tip or a nacelle can still stand clear of the
        // fuselage in the section's front part. Move the cut aft of the last column there that crosses
        // more than one solid run, keeping at least a fifth of the length.
        func runs(_ x: Int) -> Int {
            var count = 0, length = 0
            for y in 0..<h {
                if a(x, y) > 128 { length += 1 } else { if length >= 3 { count += 1 }; length = 0 }
            }
            return count + (length >= 3 ? 1 : 0)
        }
        let latest = min(Int(CGFloat(cw) * 0.45), max(0, cw - w / 5))
        var lead = 0
        for x in 0..<max(0, latest) where runs(x) > 1 { lead = x + max(2, w / 80) }
        lead = min(lead, max(0, latest))
        // The box of the section's pixels from the cut on (rows top down).
        var minY = h, maxY = -1, maxX = -1
        for y in 0..<h {
            for x in lead..<cw where a(x, y) > 5 {
                minY = min(minY, y); maxY = max(maxY, y); maxX = max(maxX, x)
            }
        }
        guard maxY > minY, maxX > lead else { return nil }
        // The fuselage at the cut: the longest opaque run down a column just inside the edge.
        let column = min(lead + 2, maxX)
        var best = (start: -1, end: -1), run = -1
        for y in minY...maxY {
            if a(column, y) > 128 {
                if run < 0 { run = y }
                if y - run > best.end - best.start { best = (run, y) }
            } else {
                run = -1
            }
        }
        guard best.start >= 0,
              let image = full.cropping(to: CGRect(x: x0 + lead, y: minY, width: maxX - lead + 1, height: maxY - minY + 1))
        else { return nil }
        return TailSection(image: image, barrelTop: CGFloat(best.start - minY), barrelBottom: CGFloat(best.end - minY + 1))
    }

    /// How the section sits in a block of `size`: scale (points per pixel) and its top-left corner, with
    /// the fuselage across the block, the fin rising at most `rise` above its top and the tail tip `inset`
    /// short of its right edge. `barrelShare` is the fuselage's part of the block's height.
    static func layout(_ section: TailSection, in size: CGSize, rise: CGFloat, inset: CGFloat,
                       barrelShare: CGFloat = 0.5, barrelCentre: CGFloat = 0.56) -> (scale: CGFloat, origin: CGPoint) {
        let centre = size.height * barrelCentre
        // As large as the fuselage share asks, and wide enough to reach the block's left edge.
        var scale = max(barrelShare * size.height / section.barrel, (size.width - inset) / section.width)
        // No taller than the block takes for the fuselage, the room above for the fin, and the block's floor.
        scale = min(scale, 0.74 * size.height / section.barrel)
        scale = min(scale, (rise + centre) / max(1, section.barrelMid))
        scale = min(scale, (size.height - centre - 2) / max(1, section.height - section.barrelMid))
        let origin = CGPoint(x: size.width - inset - section.width * scale, y: centre - section.barrelMid * scale)
        return (scale, origin)
    }
}

/// Tail sections cut so far, by side view key or drawing key.
@MainActor
enum TailSectionMemo {
    private static var held: [String: TailSection] = [:]

    static func section(_ key: String, _ make: () -> TailSection?) -> TailSection? {
        if let section = held[key] { return section }
        guard let section = make() else { return nil }
        if held.count > 64 { held = [:] }
        held[key] = section
        return section
    }
}

/// An aircraft's tail rising out of a block: the rear fuselage runs across the block, cut hard at its left
/// edge and floor, and the fin stands above its top edge, up to `rise`. Nose left, so the fin is on the
/// right. The block itself (its colour) is the caller's; this view draws only the aircraft, clear around it.
struct AircraftTail: View {
    var type: AircraftType?
    var airline: Airline?
    /// How far the fin may stand above the block.
    var rise: CGFloat
    @Environment(\.brandAssets) private var service
    @Environment(\.reference) private var reference
    @Environment(\.displayScale) private var displayScale
    @State private var revision = 0

    var body: some View {
        let _ = revision
        GeometryReader { geo in
            if let section = section {
                let inset = min(14, geo.size.width * 0.05)
                let fit = TailSection.layout(section, in: geo.size, rise: rise, inset: inset)
                let w = section.width * fit.scale, h = section.height * fit.scale
                ZStack(alignment: .topLeading) {
                    // A bar wider than the section: carry the barrel on to the block's left edge.
                    if fit.origin.x > 0, let strip = section.image.cropping(
                        to: CGRect(x: 1, y: section.barrelTop, width: 2, height: section.barrel)) {
                        Image(decorative: strip, scale: 1)
                            .resizable()
                            .frame(width: fit.origin.x + 1, height: section.barrel * fit.scale)
                            .offset(y: fit.origin.y + section.barrelTop * fit.scale)
                    }
                    Image(decorative: section.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: w, height: h)
                        .offset(x: fit.origin.x, y: fit.origin.y)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                // Hard edges at the block's left, right and floor; open above for the fin.
                .mask(alignment: .bottom) {
                    Rectangle().frame(width: geo.size.width, height: geo.size.height + rise + 4)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(AircraftImage.label(airline: airline, type: type))
        .accessibilityAddTraits(.isImage)
        .task(id: sideKey) {
            let before = AircraftArtMemo.shared.art(sideKey)?.version
            let after = await AircraftImage.load(airline: airline, type: type, service: service)
            if after?.version != before || before == nil { revision += 1 }
        }
    }

    private var sideKey: String { AircraftImage.sideKey(airline: airline, type: type) }

    /// The tail of the side view `AircraftImage` shows (never a drawing); nil until it is decoded.
    private var section: TailSection? {
        guard let art = AircraftArtMemo.shared.art(sideKey) else { return nil }
        let start = TailSection.start(type: type)
        return TailSectionMemo.section("\(sideKey)/\(art.version)") { TailSection.cut(art.image, start: start) }
    }
}
