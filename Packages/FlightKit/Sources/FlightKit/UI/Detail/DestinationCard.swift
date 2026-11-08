import SwiftUI

// MARK: - Wording

/// The words of the destination card. No SwiftUI here, so the tests read the exact text.
enum DestinationCardFacts {
    static let subtitle = "Good to know before you go"
    static let esim = "Set up an eSIM or a roaming plan before you leave."

    /// "Plugs C, E" or "Plug G".
    static func plugs(_ f: DestinationFacts) -> String {
        "\(f.plugs.count == 1 ? "Plug" : "Plugs") \(f.plugs.joined(separator: ", "))"
    }

    /// "230 V", "127 V and 220 V".
    static func volts(_ f: DestinationFacts) -> String {
        f.volts.map { "\($0) V" }.joined(separator: " and ")
    }

    static func tipping(_ t: DestinationFacts.Tipping) -> String {
        switch t {
        case .none: "Tipping: not expected"
        case .roundUp: "Tipping: round up"
        case .included: "Tipping: service often included"
        case .ten: "Tipping: about 10%"
        case .tenToFifteen: "Tipping: 10 to 15%"
        case .fifteenToTwenty: "Tipping: 15 to 20%"
        }
    }

    /// "Plugs C, E · 230 V · EUR · Tipping: round up".
    static func line(_ f: DestinationFacts) -> String {
        ([plugs(f), volts(f), f.currency] + [f.tipping.map(tipping)].compactMap { $0 }).joined(separator: " · ")
    }
}

// MARK: - Card

/// On an international flight's sheet: the destination's plugs, voltage, currency and tipping custom in
/// one line, and a reminder to set up an eSIM while the plane is still on the ground.
struct DestinationCard: View {
    var country: String
    var facts: DestinationFacts
    /// False once the plane has left: the eSIM reminder is for before departure.
    var showsESIM: Bool

    var body: some View {
        DetailCard {
            CardTitle(country, subtitle: DestinationCardFacts.subtitle)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: [DestinationCardFacts.plugs(facts), DestinationCardFacts.volts(facts), facts.currency]
                        .joined(separator: " · "))
                    .scaledFont(16, weight: .medium)
                    .foregroundStyle(Theme.primary)
                if let t = facts.tipping {
                    Text(ui: DestinationCardFacts.tipping(t)).scaledFont(16).foregroundStyle(Theme.primary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .scaledPadding(.top, 12)
            if showsESIM {
                InfoRow(symbol: "simcard", title: "eSIM", text: DestinationCardFacts.esim)
                    .scaledPadding(.top, 12)
            }
        }
        .accessibilityElement(children: .combine)
        .id("destination")
    }
}
