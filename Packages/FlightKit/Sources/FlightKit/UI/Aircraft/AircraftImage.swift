import SwiftUI

/// An aircraft in colour, in profile, nose to the left, in flight with the gear up: the provider's side
/// view for this airline and type when the brand service has one (cached or fetched), else our own
/// drawing in the airline's livery (`ReferenceData.livery`), rasterised once per airline, type, height and
/// scale so list rows redraw from a bitmap. Every screen that shows an aircraft in colour goes through this
/// view; blueprint drawings always use our renderer.
public struct AircraftImage: View {
    var type: AircraftType?
    var airline: Airline?
    var height: CGFloat
    @Environment(\.brandAssets) private var service
    @Environment(\.reference) private var reference
    @Environment(\.displayScale) private var displayScale
    /// Bumped when the task stores a provider side view, so the body reads the memo again.
    @State private var revision = 0

    public init(type: AircraftType?, airline: Airline?, height: CGFloat = 72) {
        self.type = type; self.airline = airline; self.height = height
    }

    /// Where the picture comes from.
    public enum Source: Sendable, Equatable {
        case provider(BrandAsset)
        case renderer(Livery)
    }

    /// The provider side view when the service has one for this airline and type and it is a profile
    /// (`ProviderSideView.aspect` once its transparent margins are cropped), else our renderer in the
    /// airline's livery (plain without an airline).
    public static func source(airline: Airline?, type: AircraftType?, service: any BrandAssetService,
                              reference: ReferenceData = .bundled()) async -> Source {
        if let airline, let type, !type.id.isEmpty,
           let asset = await service.asset(airline.id, .sideView, type: type.id),
           await ProviderSideView.prepareOff(asset) != nil {
            return .provider(asset)
        }
        return .renderer(airline.map { reference.livery($0.id) } ?? .plain)
    }

    /// Fills the memos (provider side views and fin art) for these pairs, for renders that cannot wait
    /// for a task.
    public static func preload(_ pairs: [(airline: Airline?, type: AircraftType?)], service: any BrandAssetService) async {
        for pair in pairs {
            guard let airline = pair.airline else { continue }
            await load(airline: airline, type: pair.type, service: service)
            await FinArt.load(icao: airline.id, service: service)
        }
    }

    private var sideKey: String? {
        guard let airline, let type, !type.id.isEmpty else { return nil }
        return AircraftArtMemo.sideKey(airline.id, type.id)
    }

    @MainActor @discardableResult
    static func load(airline: Airline, type: AircraftType?, service: any BrandAssetService) async -> BrandArt? {
        guard let type, !type.id.isEmpty else { return nil }
        let key = AircraftArtMemo.sideKey(airline.id, type.id)
        switch await service.lookup(airline.id, .sideView, type: type.id) {
        case .unavailable:
            return AircraftArtMemo.shared.art(key)
        case .missing:
            AircraftArtMemo.shared.set(key, .none)
            return nil
        case .found(let asset):
            if let held = AircraftArtMemo.shared.art(key), held.version == asset.version { return held }
            let art = await ProviderSideView.prepareOff(asset)
            AircraftArtMemo.shared.set(key, art.map { .art($0) } ?? .none)
            return art
        }
    }

    public var body: some View {
        let _ = revision
        let provided = sideKey.flatMap { AircraftArtMemo.shared.art($0) }
        Group {
            if let provided {
                Image(decorative: provided.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(provided.aspect, contentMode: .fit)
                    .frame(height: height)
            } else if let raster = rendered {
                Image(decorative: raster, scale: displayScale)
                    .resizable()
                    .frame(width: height * AircraftSideView.aspect(type: type), height: height)
            } else {
                AircraftSideView(type: type, livery: livery)
                    .frame(width: height * AircraftSideView.aspect(type: type), height: height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Self.label(airline: airline, type: type))
        .accessibilityAddTraits(.isImage)
        .task(id: airline?.id ?? "") {
            guard let airline else { return }
            let before = AircraftArtMemo.shared.art(AircraftArtMemo.finKey(airline.id))?.version
            let after = await FinArt.load(icao: airline.id, service: service)
            if after?.version != before { revision += 1 }
        }
        .task(id: sideKey) {
            guard let airline, sideKey != nil else { return }
            let before = sideKey.flatMap { AircraftArtMemo.shared.art($0) }?.version
            let after = await Self.load(airline: airline, type: type, service: service)
            if after?.version != before { revision += 1 }
        }
    }

    private var livery: Livery { airline.map { reference.livery($0.id) } ?? .plain }

    /// Our drawing as a bitmap, rendered once per livery, type, height, scale and fin art.
    private var rendered: CGImage? {
        let fin = airline.flatMap { AircraftArtMemo.shared.art(AircraftArtMemo.finKey($0.id)) }
        let paint = livery
        let key = "row/\(paint.hashValue)/\(AircraftGeometry.cacheKey(type))/\(height)/\(displayScale)/\(fin?.version ?? "-")"
        if let held = AircraftArtMemo.shared.image(key) { return held }
        let size = CGSize(width: height * AircraftSideView.aspect(type: type), height: height)
        let canvas = AircraftCanvas(geometry: AircraftGeometry.geometry(type: type), livery: paint, style: .livery,
                                    gearDown: false, finArt: fin)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = displayScale
        guard let image = renderer.cgImage else { return nil }
        AircraftArtMemo.shared.setImage(key, image)
        return image
    }

    /// "Airbus A321 in Delta colours"; the type alone without an airline.
    nonisolated static func label(airline: Airline?, type: AircraftType?) -> String {
        switch (airline, type) {
        case let (a?, t?): "\(t.name) in \(shortName(a)) colours"
        case let (nil, t?): "\(t.name)"
        case let (a?, nil): "Aircraft in \(shortName(a)) colours"
        case (nil, nil): "Aircraft"
        }
    }

    /// The airline's name without its generic tail: "Delta Air Lines" gives "Delta".
    nonisolated static func shortName(_ airline: Airline) -> String {
        let name = airline.name
        for tail in [" Air Lines", " Airlines", " Airways", " Airline"] where name.hasSuffix(tail) && name.count > tail.count {
            return String(name.dropLast(tail.count))
        }
        return name
    }
}

#if DEBUG
#Preview("Aircraft images") {
    let reference = ReferenceData.bundled()
    VStack(spacing: 20) {
        AircraftImage(type: reference.type("B77W"), airline: reference.airline("UAL"))
        AircraftImage(type: reference.type("A320"), airline: reference.airline("AFR"), height: 40)
        AircraftImage(type: nil, airline: nil, height: 40)
    }
    .padding()
    .background(Color(red: 0.80, green: 0.86, blue: 0.95))
}
#endif
