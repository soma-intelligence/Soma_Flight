import CoreLocation
import MapKit
import SwiftUI

/// The radar: a map of the planes in the air around the user (when location is already allowed) or around a
/// chosen airport. Tap a plane for its flight and to follow it; it refreshes every minute while it is on
/// screen and stops when it is hidden (the refresh loop lives in this view's `.task`).
public struct RadarView: View {
    @State private var store: RadarStore
    @State private var camera: MapCameraPosition = .automatic
    @State private var code = ""
    @State private var unknownCode = false
    var onClose: () -> Void

    public init(store: RadarStore, onClose: @escaping () -> Void) {
        _store = State(initialValue: store)
        self.onClose = onClose
    }

    public var body: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            if case .me = store.place, let c = store.place?.coordinate {
                Annotation("", coordinate: c, anchor: .center) {
                    Circle().fill(Theme.accent).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .accessibilityLabel(Text("Your location"))
                }
            }
            if case let .airport(a) = store.place {
                Annotation(a.iata ?? a.id, coordinate: store.place!.coordinate, anchor: .center) {
                    Image(systemName: "building.2.fill").font(.system(size: 12)).foregroundStyle(.white)
                        .padding(6).background(Circle().fill(.black.opacity(0.55)))
                }
            }
            ForEach(store.flights) { flight in
                Annotation("", coordinate: flight.coordinate, anchor: .center) {
                    Button { store.selectedID = flight.id } label: {
                        RadarPlane(flight: flight, selected: flight.id == store.selectedID,
                                   followed: flight.id == store.followedID)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .overlay(alignment: .top) { header }
        .overlay(alignment: .bottom) { bottom }
        .overlay { if store.place == nil { placePicker } }
        .task { await store.run() }
        .onChange(of: store.cameraSerial) { moveCamera() }
        .onAppear { moveCamera() }
    }

    // MARK: Pieces

    private var title: LocalizedStringKey {
        switch store.place {
        case .me: "Flights around you"
        case let .airport(a): "Flights near \(a.iata ?? a.id)"
        case nil: "Nearby Flights"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let note = statusNote { Text(note).font(.caption).foregroundStyle(Theme.secondary) }
            }
            Spacer(minLength: 8)
            if store.place != nil { airportMenu }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private var statusNote: LocalizedStringKey? {
        switch store.status {
        case .failed: "The radar is unavailable right now."
        case .loading: "Looking for planes"
        case .needsPlace: nil
        case .ready:
            if store.stale { "Not the latest positions" }
            else if store.flights.isEmpty { "No flights in the air here right now." }
            else if store.truncated { "More flights are in this area than shown" }
            else { "\(store.flights.count) in the air" }
        }
    }

    private var airportMenu: some View {
        Menu {
            Button("Around Me") { Task { _ = await store.useMyLocation() } }
            ForEach(Self.suggestions, id: \.self) { c in Button(c) { store.choose(code: c) } }
        } label: {
            Image(systemName: "location.magnifyingglass").font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(Text("Change Place"))
    }

    static let suggestions = ["SFO", "JFK", "LAX", "LHR", "CDG", "FRA"]

    /// With no location permission and no airport yet: ask for an airport code. Never asks for location.
    private var placePicker: some View {
        VStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 30)).foregroundStyle(Theme.secondary)
            Text("Enter an airport code to see flights in the air around it.")
                .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(Theme.secondary)
            TextField("Airport code", text: $code)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 200).multilineTextAlignment(.center)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .onSubmit(submit)
            if unknownCode { Text("That airport code is not known.").font(.caption).foregroundStyle(Theme.veryLate) }
            Button("Show Flights", action: submit).buttonStyle(.borderedProminent).disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            HStack { ForEach(Self.suggestions.prefix(4), id: \.self) { c in Button(c) { store.choose(code: c) }.buttonStyle(.bordered) } }
        }
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 24)
    }

    private func submit() {
        unknownCode = !store.choose(code: code)
    }

    @ViewBuilder private var bottom: some View {
        if let flight = store.selected {
            RadarCard(flight: flight, following: flight.id == store.followedID,
                      follow: { store.follow(flight) }, unfollow: { store.stopFollowing() },
                      dismiss: { store.selectedID = nil })
                .padding(.horizontal, 12).padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func moveCamera() {
        let focus = store.followed?.coordinate ?? store.place?.coordinate
        guard let focus else { return }
        let metres = RadarStore.defaultRadiusKm * 2_300
        withAnimation(.smooth) {
            camera = .camera(MapCamera(centerCoordinate: focus, distance: metres))
        }
    }
}

/// A plane on the radar, turned to its heading. The SF Symbol points east, so 0 (north) turns it -90.
struct RadarPlane: View {
    var flight: NearbyFlight
    var selected: Bool
    var followed: Bool

    var body: some View {
        Image(systemName: "airplane")
            .scaledFont(selected ? 22 : 17, weight: .bold)
            .foregroundStyle(followed ? Theme.friend : Color.white)
            .shadow(color: .black.opacity(0.6), radius: 1.5)
            .rotationEffect(.degrees((flight.heading ?? 90) - 90))
            .padding(6)
            .background(Circle().fill(.black.opacity(selected ? 0.5 : 0)))
            .animation(.snappy, value: selected)
            .accessibilityLabel(Text(flight.ident))
    }
}

/// What the tapped plane is: its line, route, height and speed, and the follow switch.
struct RadarCard: View {
    var flight: NearbyFlight
    var following: Bool
    var follow: () -> Void
    var unfollow: () -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(flight.ident).font(.title3.weight(.semibold))
                if let type = flight.type { Text(type).font(.subheadline).foregroundStyle(Theme.secondary) }
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary) }
                    .buttonStyle(.plain).accessibilityLabel(Text("Close"))
            }
            if let route = Self.route(flight) { Text(route).font(.headline) }
            HStack(spacing: 18) {
                if let alt = flight.altitudeFeet { stat(Self.altitudeText(alt), "Altitude") }
                if let kt = flight.groundspeedKnots { stat(Self.speedText(kt), "Speed") }
                if let h = flight.heading { stat("\(Int(h))°", "Heading") }
            }
            Button(action: following ? unfollow : follow) {
                Text(following ? "Stop Following" : "Follow").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func stat(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline.weight(.semibold))
            Text(label).font(.caption).foregroundStyle(Theme.secondary)
        }
    }

    /// "SFO to LHR", or what is known of it.
    static func route(_ f: NearbyFlight) -> String? {
        switch (f.origin, f.destination) {
        case let (o?, d?): "\(o) → \(d)"
        case let (o?, nil): o
        case let (nil, d?): d
        default: nil
        }
    }

    static func altitudeText(_ feet: Int) -> String {
        Measurement(value: Double(feet), unit: UnitLength.feet).formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }

    static func speedText(_ knots: Int) -> String {
        Measurement(value: Double(knots), unit: UnitSpeed.knots).formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }
}

/// The map screen's way in: a round button that opens the radar over the globe. Draws nothing when the radar
/// is off (`RadarEnabled` NO, or no backend), so a build without it shows no button.
public struct RadarEntryButton: View {
    var env: AppEnvironment
    @State private var open = false

    public init(env: AppEnvironment) { self.env = env }

    public var body: some View {
        if env.nearby.isAvailable {
            Button { open = true } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(Text("Nearby Flights"))
            #if os(iOS)
            .fullScreenCover(isPresented: $open) {
                RadarView(store: env.makeRadarStore(), onClose: { open = false })
            }
            #else
            .sheet(isPresented: $open) {
                RadarView(store: env.makeRadarStore(), onClose: { open = false })
                    .frame(minWidth: 520, minHeight: 520)
            }
            #endif
        }
    }
}

public extension AppEnvironment {
    /// A radar over this environment: the fakes' traffic with `-useFakes`, the backend's otherwise, and the
    /// user's place only when location is already allowed.
    @MainActor func makeRadarStore() -> RadarStore {
        RadarStore(service: nearby, locator: nearby is FakeNearbyFlightsService
                       ? FakeRadarLocator(CLLocationCoordinate2D(latitude: 37.62, longitude: -122.38)) : SystemRadarLocator(),
                   lookup: lookup)
    }
}
