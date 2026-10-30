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

    /// The buttons in order; a missing or unsafe value leaves its button out. The reference data holds X
    /// and Facebook as bare handles ("AlaskaAir"); the links are built here on the two sites' https hosts.
    static func buttons(_ a: Airline) -> [Link] {
        var out: [Link] = []
        if let phone = a.phone, let url = phoneURL(phone) { out.append(Link(title: "PHONE", url: url)) }
        if let w = SafeLink.web(a.website) { out.append(Link(title: "WEBSITE", url: w)) }
        if let h = SafeLink.handle(a.x), let url = URL(string: "https://x.com/\(h)") {
            out.append(Link(title: "X", url: url))
        }
        if let h = SafeLink.handle(a.facebook), let url = URL(string: "https://www.facebook.com/\(h)") {
            out.append(Link(title: "FACEBOOK", url: url))
        }
        return out
    }

    /// `tel:` with the digits and a leading "+"; nil for a vanity number ("1-800-UNITED"), whose letters
    /// would dial something else, or one without digits.
    static func phoneURL(_ phone: String) -> URL? {
        guard !phone.contains(where: \.isLetter) else { return nil }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard digits.contains(where: \.isNumber) else { return nil }
        return URL(string: "tel:\(digits)")
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
                        // One word callsigns (SOUTHWEST) shrink rather than break mid-word.
                        Text(code.value).scaledFont(18).foregroundStyle(Theme.primary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .scaledPadding(.top, 18)
        }
    }
}

/// The only links the flight sheet opens from data: web pages on http or https (as the data has them) with
/// no query, fragment or credentials, and social handles made of letters, digits, "_" and ".".
enum SafeLink {
    static func web(_ url: URL?) -> URL? {
        guard let url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = c.host, !host.isEmpty else { return nil }
        c.scheme = scheme
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        return c.url
    }

    /// The handle in a bare value ("AlaskaAir", "@AlaskaAir") or a profile link ("https://x.com/AlaskaAir").
    static func handle(_ raw: URL?) -> String? {
        guard let raw else { return nil }
        var text = raw.absoluteString
        if raw.scheme != nil || text.contains("/") {
            text = raw.path.split(separator: "/").first.map(String.init) ?? ""
        }
        if text.hasPrefix("@") { text.removeFirst() }
        guard !text.isEmpty, text.count <= 64,
              text.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0)
                  || ("0"..."9").contains($0) || $0 == "_" || $0 == "." }),
              text.contains(where: { $0 != "." }) else { return nil }
        return text
    }
}
