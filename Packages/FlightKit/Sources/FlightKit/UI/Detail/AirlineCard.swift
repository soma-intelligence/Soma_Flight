import SwiftUI

/// The airline behind the flight, from the bundled reference data: logo, name and alliance, buttons for
/// its phone, website, X and Facebook (each only when known), then its ATC callsign, ICAO and IATA codes.
/// Draws nothing when the airline is unknown.
struct AirlineCard: View {
    struct Link: Hashable { var title: String; var url: URL }
    struct Code: Hashable { var label: String; var value: String }

    var airline: Airline?
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The buttons in order; a missing value leaves its button out.
    static func buttons(_ a: Airline) -> [Link] {
        var out: [Link] = []
        if let phone = a.phone {
            let digits = phone.filter { $0.isNumber || $0 == "+" }
            if !digits.isEmpty, let url = URL(string: "tel:\(digits)") { out.append(Link(title: "PHONE", url: url)) }
        }
        if let w = a.website { out.append(Link(title: "WEBSITE", url: w)) }
        if let x = a.x { out.append(Link(title: "X", url: x)) }
        if let f = a.facebook { out.append(Link(title: "FACEBOOK", url: f)) }
        return out
    }

    static func codes(_ a: Airline) -> [Code] {
        [Code(label: "ATC Callsign", value: a.callsign ?? "--"),
         Code(label: "ICAO", value: a.id),
         Code(label: "IATA", value: a.iata ?? "--")]
    }

    var body: some View {
        if let airline { card(airline) }
    }

    private func card(_ airline: Airline) -> some View {
        DetailCard {
            HStack(spacing: 14) {
                AirlineLogo(airline: airline, code: airline.id, size: 48, decorative: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(airline.name).scaledFont(22, weight: .bold).foregroundStyle(Theme.primary)
                    if let alliance = airline.alliance {
                        Text(alliance.title).scaledFont(16, weight: .medium).foregroundStyle(Theme.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
            let links = Self.buttons(airline)
            if !links.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                         count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                    ForEach(links, id: \.self) { link in
                        Button { openURL(link.url) } label: {
                            Text(link.title)
                                .scaledFont(15, weight: .medium)
                                .foregroundStyle(Theme.primary)
                                .frame(maxWidth: .infinity)
                                .scaledPadding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.pill))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(link.title == "X" ? "X" : link.title.capitalized)
                    }
                }
                .scaledPadding(.top, 16)
            }
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                ForEach(Self.codes(airline), id: \.self) { code in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(code.label).scaledFont(15, weight: .medium).foregroundStyle(Theme.secondary)
                        Text(code.value).scaledFont(18).foregroundStyle(Theme.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .scaledPadding(.top, 18)
        }
    }
}
