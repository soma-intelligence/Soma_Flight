import SwiftUI

/// The words of the flight sheet's travel documents card. No SwiftUI here, so the tests read the exact text.
enum TravelDocumentsCardFacts {
    /// "Your Air France number" or "Your Flying Blue number".
    static func ownTitle(_ n: LoyaltyNumber, airline: Airline?) -> String {
        "Your \(n.programme ?? airline?.name ?? n.airline) number"
    }

    /// "United, Star Alliance partner".
    static func partnerTitle(_ n: LoyaltyNumber, airline: Airline?) -> String {
        let name = n.programme ?? airline?.name ?? n.airline
        return airline?.alliance.map { "\(name), \($0.title) partner" } ?? name
    }
}

/// On the flight sheet, under the airline: the traveller's loyalty number for this airline (or its
/// alliance partners) with a copy button, and a word about the passport before an international flight
/// when it expires within six months. Hidden when the vault has nothing to say for this flight.
struct TravelDocumentsCard: View {
    var airline: Airline?
    var departure: Date?
    var international: Bool
    @Environment(\.travelDocuments) private var documents
    @Environment(\.reference) private var reference
    @State private var copied: UUID?

    var body: some View {
        if let documents {
            let match = documents.loyalty(for: airline, reference: reference)
            let passport = documents.passportNotice(departure: departure, international: international)
            if match.own != nil || !match.partners.isEmpty || passport != nil {
                DetailCard {
                    VStack(alignment: .leading, spacing: 0) {
                        if let own = match.own {
                            row(own, title: TravelDocumentsCardFacts.ownTitle(own, airline: airline))
                        }
                        ForEach(match.partners) { n in
                            if match.own != nil || n.id != match.partners.first?.id { Hairline().scaledPadding(.vertical, 12) }
                            row(n, title: TravelDocumentsCardFacts.partnerTitle(n, airline: reference.airline(n.airline)))
                        }
                        if let passport {
                            if match.own != nil || !match.partners.isEmpty { Hairline().scaledPadding(.vertical, 12) }
                            InfoRow(symbol: "person.text.rectangle.fill", tint: Theme.late, title: passport.title,
                                    titleTint: Theme.late, text: passport.text)
                        }
                    }
                }
            }
        }
    }

    private func row(_ n: LoyaltyNumber, title: String) -> some View {
        HStack(spacing: 8) {
            InfoRow(symbol: "star.circle.fill", title: title, text: copied == n.id ? "\(n.number), copied" : n.number)
            Button {
                Clipboard.copy(n.number, sensitive: false)
                copied = n.id
            } label: {
                Image(systemName: copied == n.id ? "checkmark" : "doc.on.doc")
                    .scaledFont(17, weight: .medium)
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy \(title)")
        }
    }
}
