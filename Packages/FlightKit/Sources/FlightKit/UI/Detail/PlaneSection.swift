import SwiftUI

/// Where is my plane: the aircraft in the airline's colours on our own dark gradient, its name and
/// registration, then the chain of flights it flies before this one ("This flight" first, then the inbound
/// legs newest first, each airport between them). The chain is paid data, so only builds with insights on
/// (and screenshot runs on the fakes) have it. Nothing draws when the type is unknown and the chain is empty.
struct PlaneSection: View {
    var flight: Flight
    var type: AircraftType?
    var airline: Airline?
    var inbound: [InboundLeg]

    static let title = "Where is my plane?"

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
            VStack(alignment: .leading, spacing: 3) {
                Text(ui: Self.title)
                    .scaledFont(22, weight: .bold)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                let line = [type?.name ?? flight.aircraftType, flight.registration].compactMap { $0 }
                if !line.isEmpty {
                    Text(line.joined(separator: " · ")).scaledFont(17, weight: .medium).foregroundStyle(.white.opacity(0.7))
                }
            }
            .scaledPadding(.horizontal, 16)
            .scaledPadding(.top, 20)
            if let type {
                // The drawing is as wide as its height allows; fit it to the card's width.
                GeometryReader { geo in
                    AircraftImage(type: type, airline: airline, height: geo.size.height)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .aspectRatio(AircraftSideView.aspect(type: type), contentMode: .fit)
                .frame(maxWidth: .infinity)
                .scaledPadding(.vertical, 22)
                .scaledPadding(.horizontal, 16)
            }
            if !inbound.isEmpty { chain.scaledPadding(.horizontal, 12).scaledPadding(.bottom, 16) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
        .environment(\.colorScheme, .dark)
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
