import SwiftUI

/// An aircraft in colour, in profile, nose to the left, in flight with the gear up: always a photoreal side
/// view, never our drawing (the vector renderer is for blueprints only). The brand service's picture for
/// this airline and type when it has one (cached or fetched), else the next best bundled one
/// (`BundledSideViews.fallbackKey`: the parent airline's livery, the type in plain white, the closest type of
/// its family). Every screen that shows an aircraft in colour goes through this view.
public struct AircraftImage: View {
    var type: AircraftType?
    var airline: Airline?
    var height: CGFloat
    @Environment(\.brandAssets) private var service
    /// Bumped when the task stores a side view, so the body reads the memo again.
    @State private var revision = 0

    public init(type: AircraftType?, airline: Airline?, height: CGFloat = 72) {
        self.type = type; self.airline = airline; self.height = height
    }

    /// Where the picture comes from.
    public enum Source: Sendable, Equatable {
        /// The service's picture of this airline and type (exact, or its own fallback).
        case provider(BrandAsset)
        /// A bundled picture standing in (`BundledSideViews.fallbackKey`).
        case bundled(String)
        /// Nothing at all: only with an empty bundle.
        case none
    }

    /// The service's side view when it has one for this airline and type and it reads as a profile
    /// (`ProviderSideView.aspect` once its transparent margins are cropped), else the bundled stand-in.
    public static func source(airline: Airline?, type: AircraftType?, service: any BrandAssetService) async -> Source {
        if let airline, let type, !type.id.isEmpty,
           let asset = await service.asset(airline.id, .sideView, type: type.id),
           await ProviderSideView.prepareOff(asset) != nil {
            return .provider(asset)
        }
        return fallbackKey(airline: airline, type: type).map { .bundled($0) } ?? .none
    }

    /// The bundled stand-in for this airline and type.
    static func fallbackKey(airline: Airline?, type: AircraftType?) -> String? {
        if let type, type.id.isEmpty { return BundledSideViews.fallbackKey(airline?.id, family: type.family) }
        return BundledSideViews.fallbackKey(airline?.id, type: type?.id)
    }

    /// Fills the memo for these pairs, for renders that cannot wait for a task.
    public static func preload(_ pairs: [(airline: Airline?, type: AircraftType?)], service: any BrandAssetService) async {
        for pair in pairs { await load(airline: pair.airline, type: pair.type, service: service) }
    }

    /// The memo key: one per airline and type, unknown ones included ("ZZZ" without an airline, "" without
    /// a type).
    static func sideKey(airline: Airline?, type: AircraftType?) -> String {
        AircraftArtMemo.sideKey(airline?.id ?? BundledSideViews.plainAirline, type.map { $0.id.isEmpty ? $0.family.rawValue : $0.id } ?? "")
    }

    private var sideKey: String { Self.sideKey(airline: airline, type: type) }

    @MainActor @discardableResult
    static func load(airline: Airline?, type: AircraftType?, service: any BrandAssetService) async -> BrandArt? {
        let key = sideKey(airline: airline, type: type)
        var asset: BrandAsset?
        if let airline, let type, !type.id.isEmpty {
            switch await service.lookup(airline.id, .sideView, type: type.id) {
            case .found(let found): asset = found
            case .unavailable: if let held = AircraftArtMemo.shared.art(key) { return held }
            case .missing: break
            }
        }
        if let asset, let art = await prepare(asset, key: key) { return art }
        // The service has nothing usable: the bundled stand-in, never a drawing.
        guard let stand = fallbackKey(airline: airline, type: type).flatMap(BundledSideViews.asset(key:)) else {
            AircraftArtMemo.shared.set(key, .none)
            return nil
        }
        return await prepare(stand, key: key)
    }

    @MainActor
    private static func prepare(_ asset: BrandAsset, key: String) async -> BrandArt? {
        if let held = AircraftArtMemo.shared.art(key), held.version == asset.version {
            return held
        }
        guard let art = await ProviderSideView.prepareOff(asset) else { return nil }
        AircraftArtMemo.shared.set(key, .art(art))
        return art
    }

    public var body: some View {
        let _ = revision
        let provided = AircraftArtMemo.shared.art(sideKey)
        Group {
            if let provided {
                Image(decorative: provided.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(provided.aspect, contentMode: .fit)
                    .frame(height: height)
            } else {
                // Until the picture is decoded: the space it will take, empty.
                Color.clear
                    .frame(width: height * AircraftSideView.aspect(type: type), height: height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Self.label(airline: airline, type: type))
        .accessibilityAddTraits(.isImage)
        .task(id: sideKey) {
            let before = AircraftArtMemo.shared.art(sideKey)?.version
            let after = await Self.load(airline: airline, type: type, service: service)
            if after?.version != before || before == nil { revision += 1 }
        }
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
