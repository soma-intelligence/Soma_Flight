import SwiftUI

// MARK: - Card

/// A flat card (R6): `Theme.card` fill, `Theme.cardRadius` corners, no stroke, no coloured top. An optional
/// 4 pt severity bar runs down its leading edge (R3, R7).
/// Penpot: Card (Card/Status with a severity bar)
public struct RefinedCard<Content: View>: View {
    var severity: Color?
    var padding: CGFloat
    var content: Content
    @Environment(\.metricsScale) private var scale

    /// - Parameters:
    ///   - severity: the leading bar's colour; no bar when nil.
    ///   - padding: inner padding in reference points.
    public init(severity: Color? = nil, padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.severity = severity; self.padding = padding; self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.metric(Theme.cardRadius, scale), style: .continuous)
        content
            .scaledPadding(.all, padding)
            .scaledPadding(.leading, severity == nil ? 0 : 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Theme.card
                    if let severity {
                        severity.frame(width: Theme.metric(4, scale))
                    }
                }
            }
            .clipShape(shape)
    }
}

// MARK: - Section label

/// The small caps label above a card, in secondary colour, outside the card (R6). An optional trailing
/// word: plain text, or a 44 pt tall button when it has an action.
/// Penpot: Section label
public struct SectionLabel: View {
    var title: String
    var trailing: String?
    var action: (() -> Void)?

    public init(_ title: String, trailing: String? = nil, action: (() -> Void)? = nil) {
        self.title = title; self.trailing = trailing; self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ui: title)
                .foregroundStyle(Theme.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let trailing {
                if let action {
                    Button(action: action) {
                        Text(ui: trailing)
                            .foregroundStyle(Theme.accent)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(ui: trailing).foregroundStyle(Theme.secondary)
                }
            }
        }
        .scaledFont(12, weight: .medium)
        .textCase(.uppercase)
        .lineLimit(1)
        .scaledPadding(.horizontal, Theme.gutter)
    }
}

#Preview("Cards") {
    VStack(alignment: .leading, spacing: 8) {
        SectionLabel("Upcoming", trailing: "3 flights")
        RefinedCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("Booking code").themeFont(.sectionTitle)
                Text("Tap to edit").themeFont(.sectionSubtitle).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 20)
        SectionLabel("Delays", trailing: "See all") {}
        RefinedCard(severity: Theme.late) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Landing 11m late").scaledFont(19, weight: .semibold).foregroundStyle(Theme.late)
                Text("Air France · in the air · arrives in 6h 49m").themeFont(.sectionSubtitle)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 20)
    }
    .padding(.vertical, 20)
    .background(Theme.background)
}
