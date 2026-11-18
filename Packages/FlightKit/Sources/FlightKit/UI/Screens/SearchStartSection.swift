import SwiftUI

/// Search before anything is typed (R8, A10), the parts of `SearchView.suggestions`: flat cards of rows
/// under small caps labels, and the example chips that fill the field.
/// Penpot: Proposal · Search start
enum SearchExamples {
    /// The examples offered under the recent searches: a flight number, a route, and a number with a day
    /// in loose words. Each fills the field when tapped.
    static let examples = ["AF 84", "SFO to JFK", "84 af tomorrow"]
}

/// One section: its small caps label outside the card, then the rows in a flat card, hairlines between.
struct SearchStartCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            RefinedCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) { content }
            }
            .scaledPadding(.horizontal, Theme.gutter)
        }
    }
}

/// A row of a start card: a square tile (a symbol on grey, or on the accent for an action), a title and
/// a grey line, and a chevron. `divider` draws the hairline under it, from the text's edge.
struct SearchStartRow<Icon: View>: View {
    var title: String
    var subtitle: String?
    var divider: Bool
    @ViewBuilder var icon: Icon
    var action: () -> Void
    @Environment(\.metricsScale) private var scale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon
                    .frame(width: Theme.metric(36, scale), height: Theme.metric(36, scale))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ui: title)
                        .themeFont(.body)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(ui: subtitle)
                            .themeFont(.label)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(Theme.secondary.opacity(0.7))
                    .accessibilityHidden(true)
            }
            .scaledPadding(.horizontal, 16)
            .scaledPadding(.vertical, 12)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .overlay(alignment: .bottom) {
            if divider { Hairline(leading: 16 + Theme.metric(36, scale) + 14) }
        }
    }
}

extension SearchStartRow where Icon == SearchSymbolTile {
    /// A row whose tile is an SF Symbol on grey, or on the accent when `prominent`.
    init(symbol: String, prominent: Bool = false, title: String, subtitle: String?, divider: Bool,
         action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, divider: divider,
                  icon: { SearchSymbolTile(symbol: symbol, prominent: prominent) }, action: action)
    }
}

/// A symbol in a rounded square: the page colour on grey, or on the accent for an action row (Import).
struct SearchSymbolTile: View {
    var symbol: String
    var prominent: Bool
    @Environment(\.metricsScale) private var scale

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.metric(9, scale), style: .continuous)
            .fill(prominent ? Theme.accent : Theme.secondary.opacity(0.85))
            .overlay {
                Image(systemName: symbol)
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(Theme.background)
            }
    }
}

/// The example chips: grey capsules in one line, or stacked when they do not fit. Each is a 44 pt tall
/// button that fills the field with its words.
struct SearchExampleChips: View {
    var examples: [String] = SearchExamples.examples
    var onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Examples")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { chips }
                VStack(alignment: .leading, spacing: 0) { chips }
            }
            .scaledPadding(.horizontal, Theme.gutter)
        }
    }

    private var chips: some View {
        ForEach(examples, id: \.self) { example in
            Button { onPick(example) } label: {
                Text(ui: example)
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .fixedSize()
                    .scaledPadding(.horizontal, 14)
                    .scaledPadding(.vertical, 7)
                    .background(Capsule().fill(Theme.pill))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(ui: "Example, \(example)"))
            .accessibilityHint(Text(ui: "Fills the search field"))
        }
    }
}

#Preview("Search start parts") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            SearchStartCard(title: "Recent searches") {
                SearchStartRow(symbol: "airplane", title: "AF 84", subtitle: "Air France · Paris to San Francisco",
                               divider: true) {}
                SearchStartRow(symbol: SearchView.routeIcon, title: "SFO to JFK",
                               subtitle: "San Francisco (SFO) · New York (JFK)", divider: false) {}
            }
            SearchExampleChips { _ in }
            SearchStartCard(title: "More") {
                SearchStartRow(symbol: "square.and.arrow.down", prominent: true, title: "Import flights",
                               subtitle: "From an app, your calendar, email or CSV", divider: false) {}
            }
        }
        .padding(.vertical, 20)
    }
    .background(Theme.background)
}
