import SwiftUI

// MARK: - Wording

/// The words of the cancellation kit. No SwiftUI here, so the tests read the exact text.
enum CancellationKitFacts {
    static func title(_ f: Flight) -> String {
        f.status == .canceled ? "Flight canceled: what to do" : "Long delay: what to do"
    }

    static let subtitle = "Call the airline or rebook online"

    /// "Call Air France".
    static func call(_ c: AirlineContact) -> String { "Call \(c.name)" }

    static let rebook = "Rebook Online"

    static let askTitle = "What to ask the agent"

    /// The plain checklist for the call or the desk.
    static let asks: [String] = [
        "A seat on the next flight, on a partner airline too",
        "A refund if you would rather not travel",
        "Meal vouchers while you wait",
        "A hotel and transport if the wait runs overnight",
        "Keep every receipt for food, hotel and transport",
    ]

    static let note = "What the airline owes depends on its own rules and the country. Information only."
}

// MARK: - Card

/// On a canceled flight, or one delayed 3 hours or more (`CancellationKit.isShown`): the airline's line and
/// rebooking page when the bundled table knows them (`AirlineContacts`), and what to ask for.
struct CancellationKitCard: View {
    var flight: Flight
    var contact: AirlineContact?
    @Environment(\.openURL) private var openURL

    var body: some View {
        DetailCard {
            CardTitle(CancellationKitFacts.title(flight), subtitle: contact == nil ? nil : CancellationKitFacts.subtitle)
            if let contact {
                VStack(spacing: 10) {
                    if let tel = contact.phoneURL {
                        action(CancellationKitFacts.call(contact), symbol: "phone.fill") { openURL(tel) }
                    }
                    if contact.rebook.scheme == "https" {
                        action(CancellationKitFacts.rebook, symbol: "arrow.triangle.2.circlepath") { openURL(contact.rebook) }
                    }
                }
                .scaledPadding(.top, 14)
            }
            Text(ui: CancellationKitFacts.askTitle)
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(Theme.primary)
                .scaledPadding(.top, 16)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(CancellationKitFacts.asks, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .scaledFont(15, weight: .medium)
                            .foregroundStyle(Theme.secondary)
                            .accessibilityHidden(true)
                        Text(ui: item).scaledFont(16).foregroundStyle(Theme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .scaledPadding(.top, 8)
            Text(ui: CancellationKitFacts.note)
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 12)
        }
        .id("cancellationKit")
    }

    private func action(_ title: String, symbol: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label { Text(ui: title) } icon: { Image(systemName: symbol) }
                .scaledFont(16, weight: .semibold)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.12)))
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
    }
}
