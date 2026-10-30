import SwiftUI

/// An aircraft in colour, in profile, nose to the left, in flight with the gear up: the provider's side
/// view for this airline and type when the brand service has one (cached or fetched), else our own
/// drawing (`AircraftSideView`) in the airline's livery (`ReferenceData.livery`). Every screen that shows
/// an aircraft in colour goes through this view; blueprint drawings always use our renderer.
public struct AircraftImage: View {
    var type: AircraftType?
    var airline: Airline?
    var height: CGFloat
    @Environment(\.brandAssets) private var service
    @Environment(\.reference) private var reference
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

    /// The provider side view when the service has one for this airline and type, else our renderer in the
    /// airline's livery (plain without an airline).
    public static func source(airline: Airline?, type: AircraftType?, service: any BrandAssetService,
                              reference: ReferenceData = .bundled()) async -> Source {
        if let airline, let type, !type.id.isEmpty,
           let asset = await service.asset(airline.id, .sideView, type: type.id), asset.decodes {
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
            let art = await FinArt.decode(asset, maxPixel: 1200)
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
            } else {
                AircraftSideView(type: type, livery: airline.map { reference.livery($0.id) } ?? .plain)
                    .frame(width: height * AircraftSideView.aspect(type: type), height: height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .task(id: sideKey) {
            guard let airline, sideKey != nil else { return }
            let before = sideKey.flatMap { AircraftArtMemo.shared.art($0) }?.version
            let after = await Self.load(airline: airline, type: type, service: service)
            if after?.version != before { revision += 1 }
        }
    }

    private var label: String {
        switch (airline, type) {
        case let (a?, t?): "\(a.name) \(t.name) side view"
        case let (nil, t?): "\(t.name) side view"
        case let (a?, nil): "\(a.name) aircraft side view"
        case (nil, nil): "Aircraft side view"
        }
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
