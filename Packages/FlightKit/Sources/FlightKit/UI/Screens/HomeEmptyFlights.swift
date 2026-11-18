import SwiftUI

/// The home with nothing followed (R8): a short message with no illustration, then "Add a flight", which
/// opens Search, and the quieter "Import flights" (the same entry as Search's "More" row).
/// Penpot: Proposal · Home empty
struct HomeEmptyFlights: View {
    /// Opens Search; nil leaves the button out.
    var onAdd: (() -> Void)?
    /// Opens Import; nil leaves the button out.
    var onImport: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(ui: "No flights yet")
                .themeFont(.sheetTitle)
                .foregroundStyle(Theme.primary)
                .accessibilityAddTraits(.isHeader)
            Text(ui: "Add a flight number or a route to follow it live.")
                .themeFont(.label)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 6)
            VStack(spacing: 12) {
                if let onAdd {
                    HomeEmptyButton(title: "Add a flight", systemImage: "plus", prominent: true, action: onAdd)
                }
                if let onImport {
                    HomeEmptyButton(title: "Import flights", systemImage: "square.and.arrow.down", prominent: false,
                                    action: onImport)
                }
            }
            .scaledPadding(.top, 28)
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.center)
        .scaledPadding(.horizontal, 24)
        .scaledPadding(.vertical, 40)
    }
}

/// A 240 pt wide, 52 pt tall capsule: the accent filled one leads, the grey one follows.
private struct HomeEmptyButton: View {
    var title: String
    var systemImage: String
    var prominent: Bool
    var action: () -> Void
    @Environment(\.metricsScale) private var scale

    var body: some View {
        Button(action: action) {
            Label { Text(ui: title) } icon: { Image(systemName: systemImage) }
                .scaledFont(17, weight: .semibold)
                // White on the accent fill, as the Add button of a search result (`ResultRow`).
                .foregroundStyle(prominent ? Color.white : Theme.accent)
                .frame(maxWidth: .infinity, minHeight: Theme.metric(52, scale))
                .background(Capsule().fill(prominent ? Theme.accent : Theme.pill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: Theme.metric(240, scale))
    }
}

#Preview("Home empty") {
    HomeEmptyFlights(onAdd: {}, onImport: {})
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
}
