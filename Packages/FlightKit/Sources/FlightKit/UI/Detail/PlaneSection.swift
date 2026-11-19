import CoreLocation
import SwiftUI

/// Where is my plane: the aircraft in the airline's colours on a sky after the light where it is (`PlaneSky`), its name and
/// registration, then the chain of flights it flies before this one ("This flight" first, then the inbound
/// legs newest first, each airport between them). The chain is paid data, so only builds with insights on
/// (and screenshot runs on the fakes) have it. Nothing draws when the type is unknown and the chain is empty.
struct PlaneSection: View {
    var flight: Flight
    var type: AircraftType?
    var airline: Airline?
    var inbound: [InboundLeg]
    /// "Your 3rd flight on F-GSQA" when the traveller has flown this tail before (`TailVisitFacts`).
    var tailLine: String? = nil
    /// A flight that is over (archived, or down and in the past): the card describes the plane instead of
    /// asking where it is (`PlaneSection.isPast`).
    var isPast = false
    /// The light behind the plane (`PlaneSection.sky`); nil keeps the plain dark gradient.
    var sky: SkyPhase? = nil

    static let title = "Where is my plane?"
    static let pastTitle = "About this plane"

    /// "Where is my plane?" while the flight is ahead or in the air, "About this plane" once it is over.
    static func title(isPast: Bool) -> String { isPast ? pastTitle : title }

    /// Over: opened from the archive (Passport, a past flight), or landed with its arrival behind `now`.
    static func isPast(_ f: Flight, archived: Bool, now: Date) -> Bool {
        if archived { return true }
        guard f.status == .landed || f.status == .arrived else { return false }
        guard let arrival = arrivalTime(f) else { return true }
        return arrival <= now
    }

    /// When the flight came down: at the gate, else on the runway, else the forecast, else the schedule.
    static func arrivalTime(_ f: Flight) -> Date? {
        f.actualIn ?? f.actualOn ?? f.estimatedIn ?? f.scheduledIn
    }

    /// Where and when to read the sky. A past flight: its arrival airport at its arrival time. Otherwise
    /// `now`, at the plane's reported position when there is one, at the arrival airport once it is down
    /// or in the air without a position (its next airport), else at the departure airport.
    static func skyPlace(_ f: Flight, origin: Airport?, destination: Airport?, isPast: Bool,
                         now: Date) -> (coordinate: CLLocationCoordinate2D, time: Date)? {
        func at(_ a: Airport?) -> CLLocationCoordinate2D? { a.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }
        if isPast {
            guard let place = at(destination) ?? at(origin) else { return nil }
            return (place, arrivalTime(f) ?? f.scheduledOut ?? now)
        }
        let place: CLLocationCoordinate2D?
        switch f.status {
        case .landed, .arrived: place = at(destination) ?? at(origin)
        case .departed, .enRoute:
            place = f.position.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } ?? at(destination) ?? at(origin)
        default: place = at(origin) ?? at(destination)
        }
        return place.map { ($0, now) }
    }

    /// The sky phase for the card, nil when neither airport nor a position is known.
    static func sky(_ f: Flight, origin: Airport?, destination: Airport?, isPast: Bool, now: Date) -> SkyPhase? {
        skyPlace(f, origin: origin, destination: destination, isPast: isPast, now: now)
            .map { SkyPhase.at($0.coordinate, time: $0.time) }
    }

    static func isShown(type: AircraftType?, inbound: [InboundLeg]) -> Bool { type != nil || !inbound.isEmpty }

    /// The legs in the order the card lists them: newest first.
    static func ordered(_ legs: [InboundLeg]) -> [InboundLeg] { legs.sorted { $0.scheduledOut > $1.scheduledOut } }

    /// "On time", "12m late", "Canceled".
    static func legStatus(_ leg: InboundLeg) -> (text: String, level: DelayLevel) {
        let level = DelayLevel.for(delay: .seconds(leg.delayMinutes * 60), status: leg.status)
        let text: String = switch level {
        case .canceled: "Canceled"
        case .diverted: "Diverted"
        default: leg.delayMinutes >= 1 ? "\(Format.minutes(leg.delayMinutes)) late" : "On time"
        }
        return (text, level)
    }

    static let background = LinearGradient(
        colors: [Color(red: 0.06, green: 0.08, blue: 0.16), Color(red: 0.10, green: 0.10, blue: 0.13)],
        startPoint: .top, endPoint: .bottom)

    var body: some View {
        if Self.isShown(type: type, inbound: inbound) { card }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) { header; picture }
                .background {
                    // The sky sits behind the title and the plane only, never behind the list of flights.
                    if let sky, type != nil { PlaneSky(phase: sky, seed: PlaneSky.seed(flight.registration ?? flight.ident)) }
                }
            if !inbound.isEmpty { chain.scaledPadding(.horizontal, 12).scaledPadding(.bottom, 16) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ui: Self.title(isPast: isPast))
                .scaledFont(22, weight: .bold)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            let line = [type?.name ?? flight.aircraftType, flight.registration].compactMap { $0 }
            if !line.isEmpty {
                Text(line.joined(separator: " · ")).scaledFont(17, weight: .medium).foregroundStyle(.white.opacity(0.7))
            }
            if let tailLine {
                TailBadge(text: tailLine).scaledPadding(.top, 6)
            }
        }
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.top, 20)
    }

    @ViewBuilder private var picture: some View {
        if let type {
            // The box is the type's drawn proportions, kept before the picture is decoded; the picture
            // fits inside it both ways, so one that is longer for its height never runs past the card.
            GeometryReader { geo in
                AircraftImage(type: type, airline: airline, fit: .width(geo.size.width, maxHeight: geo.size.height))
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .aspectRatio(AircraftSideView.aspect(type: type), contentMode: .fit)
            .frame(maxWidth: .infinity)
            .scaledPadding(.vertical, 22)
            .scaledPadding(.horizontal, 16)
        }
    }

    private var chain: some View {
        let legs = Self.ordered(inbound)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up").scaledFont(15, weight: .semibold).frame(width: 28).accessibilityHidden(true)
                Text("This flight").scaledFont(17, weight: .semibold)
                Spacer(minLength: 8)
                Text(DetailFacts.countdownCaption(flight, airline: nil))
                    .scaledFont(15)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .scaledPadding(.horizontal, 10)
            .scaledPadding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
            .accessibilityElement(children: .combine)
            ForEach(legs) { leg in
                node(leg.destinationIata)
                legRow(leg)
            }
            if let last = legs.last { node(last.originIata) }
        }
    }

    private func node(_ code: String) -> some View {
        HStack(spacing: 12) {
            Circle().strokeBorder(.white.opacity(0.6), lineWidth: 2).frame(width: 14, height: 14).frame(width: 28)
            Text(ui: code).scaledFont(15, weight: .medium).foregroundStyle(.white.opacity(0.7))
        }
        .scaledPadding(.horizontal, 10)
        .scaledPadding(.vertical, 6)
        .accessibilityLabel("At \(code)")
    }

    private func legRow(_ leg: InboundLeg) -> some View {
        let status = Self.legStatus(leg)
        return HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(.white.opacity(0.3)).frame(width: 2).frame(width: 28).frame(maxHeight: .infinity)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(leg.originIata) to \(leg.destinationIata)").scaledFont(17, weight: .semibold).foregroundStyle(.white)
                Text(Format.ident(leg.ident)).scaledFont(14).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 8)
            Text(ui: status.text).scaledFont(15, weight: .medium).foregroundStyle(status.level.color)
        }
        .scaledPadding(.horizontal, 10)
        .scaledPadding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// "Your 3rd flight on F-GSQA": a small capsule under the aircraft's name.
struct TailBadge: View {
    var text: String

    var body: some View {
        Label { Text(verbatim: text) } icon: { Image(systemName: "airplane.circle.fill") }
            .scaledFont(14, weight: .semibold)
            .foregroundStyle(Theme.primary)
            .scaledPadding(.horizontal, 10)
            .scaledPadding(.vertical, 5)
            .background(Capsule().fill(Theme.pill))
            .accessibilityElement(children: .combine)
    }
}
