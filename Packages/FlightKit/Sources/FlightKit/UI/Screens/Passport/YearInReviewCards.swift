import CoreLocation
import CoreTransferable
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One Year in Review card, laid out at 360 x 640 points (9:16) and rendered at 3x into a 1080 x 1920 story
/// image. Fixed type sizes: the image is the same whatever the phone's text size. Line art on flat ink: a
/// dotted world, amber arcs, light numerals, hairline rules. No gradient, no glow, no photos.
struct YearInReviewCard: View {
    var card: YearInReview.Card
    var review: YearInReview
    var unit: DistanceUnit
    var lookup: (String) -> Airport? = PassportStore.bundledAirports

    static let size = CGSize(width: 360, height: 640)
    /// Warm white on ink, one amber accent.
    static let paper = Color(red: 0x0E / 255, green: 0x0F / 255, blue: 0x12 / 255)
    static let ink = Color(red: 0xF4 / 255, green: 0xF1 / 255, blue: 0xEA / 255)
    static let soft = ink.opacity(0.56)
    static let rule = ink.opacity(0.16)
    static let gold = Color(red: 0xE8 / 255, green: 0xA8 / 255, blue: 0x4A / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            footer
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 28)
        .frame(width: Self.size.width, height: Self.size.height)
        .background { Self.background(card) }
        .environment(\.colorScheme, .dark)
    }

    /// What the card counts, as the footer names it.
    static func title(_ card: YearInReview.Card) -> String {
        switch card {
        case .flights: "Flights"
        case .time: "In the air"
        case .places: "Places"
        case .longest: "Longest flight"
        case .delays: "Delays"
        case .favorite: "Favourites"
        }
    }

    @ViewBuilder private var content: some View {
        switch card {
        case .flights: flights
        case .time: time
        case .places: places
        case .longest: longest
        case .delays: delays
        case .favorite: favorite
        }
    }

    // MARK: Cards

    private var flights: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 18)
            RouteArt(routes: review.routes, lookup: lookup)
                .frame(height: 170)
            Spacer(minLength: 18)
            big(PassportFacts.count(review.flights))
            label(YearInReviewFacts.flights(review.flights))
            line(TravelFacts.distance(review.distanceKm, unit), size: 30, weight: .semibold)
                .padding(.top, 22)
            line(YearInReviewFacts.laps(review.earthLaps), size: 18, soft: true)
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
    }

    private var time: some View {
        let t = YearInReviewFacts.time(review.flightMinutes)
        return VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Clockface(minutes: review.flightMinutes)
                .frame(width: 150, height: 150)
                .padding(.bottom, 34)
            big(t.value)
            label(t.caption)
            if let days = YearInReviewFacts.days(review.flightMinutes) {
                line(days, size: 18, soft: true).padding(.top, 18)
            }
            if let long = YearInReviewFacts.longHauls(review.longHaul) {
                line(long, size: 18, soft: true).padding(.top, 4)
            }
            Spacer()
        }
    }

    private var places: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            big(PassportFacts.count(review.countries.count))
            label(YearInReviewFacts.countries(review.countries.count))
            CountryCodes(codes: review.countries)
                .padding(.top, 22)
            line(YearInReviewFacts.airports(review.airports.count), size: 30, weight: .semibold)
                .padding(.top, 30)
            line(review.airports.prefix(8).map { PassportLists.code($0, lookup: lookup) }.joined(separator: "  "),
                 size: 17, soft: true, mono: true)
                .padding(.top, 6)
            Spacer()
        }
    }

    @ViewBuilder private var longest: some View {
        if let l = review.longest {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                label(YearInReviewFacts.longestTitle)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    code(l.originIcao)
                    Image(systemName: "airplane").font(.system(size: 26, weight: .light)).foregroundStyle(Self.gold)
                    code(l.destinationIcao)
                }
                .padding(.top, 10)
                line(city(l.originIcao) + " \u{2192} " + city(l.destinationIcao), size: 18, soft: true)
                    .padding(.top, 2)
                RouteArt(routes: [.init(originIcao: l.originIcao, destinationIcao: l.destinationIcao, flights: 1)],
                         lookup: lookup)
                    .frame(height: 150)
                    .padding(.vertical, 26)
                line(TravelFacts.distance(l.distanceKm, unit), size: 30, weight: .semibold)
                line([PassportFacts.spacedIdent(l.ident), l.minutes.map(YearInReviewFacts.duration)]
                    .compactMap { $0 }.joined(separator: "  \u{00B7}  "), size: 18, soft: true)
                    .padding(.top, 4)
                Spacer()
            }
        }
    }

    private var delays: some View {
        let lost = YearInReviewFacts.lost(review.delayLostMinutes)
        return VStack(alignment: .leading, spacing: 0) {
            Spacer()
            big(lost.value)
            label(lost.caption)
            line(YearInReviewFacts.timed(review.timedFlights), size: 17, soft: true)
                .padding(.top, 8)
            if let p = review.punctual {
                VStack(alignment: .leading, spacing: 6) {
                    line(YearInReviewFacts.punctualTitle, size: 16, soft: true)
                    line(ReferenceData.bundled().airline(p.airline)?.name ?? p.airline, size: 30, weight: .semibold)
                    line(YearInReviewFacts.punctual(p), size: 17, soft: true)
                    Meter(share: Double(p.onTimePercent) / 100)
                        .padding(.top, 8)
                }
                .padding(.top, 48)
            }
            Spacer()
        }
    }

    private var favorite: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            if let r = review.topRoute, r.flights >= 2 {
                label(YearInReviewFacts.routeTitle)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    code(r.originIcao)
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 22, weight: .light))
                        .foregroundStyle(Self.gold)
                    code(r.destinationIcao)
                }
                .padding(.top, 10)
                line(YearInReviewFacts.times(r.flights), size: 18, soft: true).padding(.top, 2)
            }
            if let a = review.topAircraft {
                VStack(alignment: .leading, spacing: 4) {
                    label(YearInReviewFacts.aircraftTitle)
                    line(ReferenceData.bundled().type(a.type)?.name ?? a.type, size: 30, weight: .semibold)
                    line(YearInReviewFacts.times(a.flights), size: 18, soft: true)
                }
                .padding(.top, review.topRoute.map { $0.flights >= 2 } == true ? 56 : 0)
            }
            Spacer()
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: YearInReviewFacts.footer)
                    .foregroundStyle(Self.soft)
                Spacer()
                Text(verbatim: YearInReviewFacts.kicker(review).uppercased())
                    .foregroundStyle(Self.gold)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .tracking(2)
            Rectangle().fill(Self.rule).frame(height: 0.5)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Self.rule).frame(height: 0.5)
            HStack {
                Text(verbatim: Self.title(card).uppercased())
                Spacer()
                let n = review.cards.firstIndex(of: card).map { $0 + 1 } ?? 1
                Text(verbatim: String(format: "%02d / %02d", n, review.cards.count))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .tracking(2)
            .foregroundStyle(Self.soft)
        }
    }

    private func big(_ s: String) -> some View {
        Text(verbatim: s)
            .font(.system(size: 112, weight: .ultraLight))
            .tracking(-3)
            .monospacedDigit()
            .foregroundStyle(Self.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
    }

    private func label(_ s: String) -> some View {
        Text(verbatim: s)
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(Self.soft)
    }

    private func line(_ s: String, size: CGFloat, weight: Font.Weight = .regular, soft: Bool = false,
                      mono: Bool = false) -> some View {
        Text(verbatim: s)
            .font(.system(size: size, weight: weight, design: mono ? .monospaced : .default))
            .foregroundStyle(soft ? Self.soft : Self.ink)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func code(_ icao: String) -> some View {
        Text(verbatim: PassportLists.code(icao, lookup: lookup))
            .font(.system(size: 64, weight: .light))
            .tracking(-1)
            .foregroundStyle(Self.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private func city(_ icao: String) -> String { lookup(icao)?.city ?? icao }

    /// Flat ink. The card argument stays so every card can be told apart later without changing callers.
    static func background(_ card: YearInReview.Card) -> some View {
        paper
    }
}

/// The routes as amber great-circle arcs over a world drawn in dots, the airports as small rings.
private struct RouteArt: View {
    var routes: [YearInReview.Route]
    var lookup: (String) -> Airport?
    /// Spacing of the dotted land, in points.
    static let pitch: CGFloat = 4.5

    var body: some View {
        Canvas { ctx, size in
            let width = min(size.width, size.height / RouteMap.aspect)
            let rect = CGRect(x: (size.width - width) / 2, y: (size.height - width * RouteMap.aspect) / 2,
                              width: width, height: width * RouteMap.aspect)
            let land = Path(RouteMap.land(in: rect))
            var dots = Path()
            var y = rect.minY + Self.pitch / 2
            while y < rect.maxY {
                var x = rect.minX + Self.pitch / 2
                while x < rect.maxX {
                    if land.contains(CGPoint(x: x, y: y), eoFill: true) {
                        dots.addEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
                    }
                    x += Self.pitch
                }
                y += Self.pitch
            }
            ctx.fill(dots, with: .color(YearInReviewCard.ink.opacity(0.24)))
            var airports: [String: CGPoint] = [:]
            for r in routes {
                guard let a = lookup(r.originIcao), let b = lookup(r.destinationIcao) else { continue }
                let runs = RouteMap.runs(CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon),
                                         CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon))
                ctx.stroke(Path(RouteMap.arc(runs, in: rect)), with: .color(YearInReviewCard.gold),
                           style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                for x in [a, b] { airports[x.id] = RouteMap.point(lon: x.lon, lat: x.lat, in: rect) }
            }
            for p in airports.values {
                let ring = Path(ellipseIn: CGRect(x: p.x - 2.6, y: p.y - 2.6, width: 5.2, height: 5.2))
                ctx.fill(ring, with: .color(YearInReviewCard.paper))
                ctx.stroke(ring, with: .color(YearInReviewCard.ink), lineWidth: 1)
            }
        }
    }
}

/// A thin dial filled by the share of the year spent flying, at least a sliver so it never reads empty.
private struct Clockface: View {
    var minutes: Int

    var body: some View {
        let share = min(1, max(0.02, Double(minutes) / (365 * 1_440) * 12))
        ZStack {
            Circle().stroke(YearInReviewCard.rule, lineWidth: 1)
            Circle().trim(from: 0, to: share)
                .stroke(YearInReviewCard.gold, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            ForEach(0..<12) { i in
                Rectangle().fill(YearInReviewCard.soft).frame(width: 1, height: 6)
                    .offset(y: -66)
                    .rotationEffect(.degrees(Double(i) * 30))
            }
            Image(systemName: "airplane").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(YearInReviewCard.ink)
        }
    }
}

/// The visited countries as their ISO codes in hairline boxes, rows of six, three rows at most and "+N" past that.
private struct CountryCodes: View {
    var codes: [String]
    static let perRow = 6, rows = 3

    var body: some View {
        let limit = Self.perRow * Self.rows
        let shown = codes.count > limit ? Array(codes.prefix(limit - 1)) : codes
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 6, alignment: .leading), count: Self.perRow),
                  alignment: .leading, spacing: 6) {
            ForEach(shown, id: \.self) { box($0.uppercased(), accent: false) }
            if codes.count > limit { box("+\(codes.count - shown.count)", accent: true) }
        }
    }

    private func box(_ s: String, accent: Bool) -> some View {
        Text(verbatim: s)
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundStyle(accent ? YearInReviewCard.gold : YearInReviewCard.ink)
            .frame(width: 44, height: 30)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(YearInReviewCard.rule, lineWidth: 1))
    }
}

/// A hairline bar filled to the share given.
private struct Meter: View {
    var share: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(YearInReviewCard.rule).frame(height: 1)
                Capsule().fill(YearInReviewCard.gold).frame(width: geo.size.width * share, height: 3)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 6)
    }
}

// MARK: - Rendering and sharing

/// Turns the cards into story images on the device.
enum YearInReviewRender {
    /// Points to pixels: 360 x 640 at 3x is 1080 x 1920.
    static let scale: CGFloat = 3

    @MainActor static func image(_ card: YearInReview.Card, review: YearInReview, unit: DistanceUnit) -> CGImage? {
        let renderer = ImageRenderer(content: YearInReviewCard(card: card, review: review, unit: unit))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(YearInReviewCard.size)
        return renderer.cgImage
    }

    /// PNG bytes of `image`, nil when it cannot be encoded.
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// One rendered card for the share sheet, as a PNG.
struct YearInReviewImage: Transferable, Identifiable, Sendable {
    var card: YearInReview.Card
    var year: Int
    var png: Data
    var id: String { card.rawValue }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.png }
            .suggestedFileName { YearInReviewFacts.fileName($0.card, year: $0.year) }
    }
}
