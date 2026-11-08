import SwiftUI

/// Distance and time on one page of Settings: each choice is a tile showing how a value will read, the one
/// in use outlined in the accent.
struct UnitsSettingsView: View {
    @Binding var units: Units

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenTitle("Units")
                    .scaledPadding(.horizontal, Theme.gutter)
                    .scaledPadding(.top, 22)
                    .scaledPadding(.bottom, 8)
                group("Distance", footer: "Flight lengths, totals and the passport's distances.") {
                    tile(sample: "9,100", unit: "km", title: "Kilometers", selected: units.distance == .km) {
                        units.distance = .km
                    }
                    tile(sample: "5,655", unit: "mi", title: "Miles", selected: units.distance == .mi) {
                        units.distance = .mi
                    }
                }
                group("Time", footer: "Departure and arrival times everywhere in the app.") {
                    tile(sample: "18:45", unit: nil, title: "24-Hour", selected: units.clock == .h24) {
                        units.clock = .h24
                    }
                    tile(sample: "6:45", unit: "PM", title: "12-Hour", selected: units.clock == .h12) {
                        units.clock = .h12
                    }
                }
            }
            .scaledPadding(.bottom, 32)
        }
        .background(Theme.background)
    }

    private func group<Tiles: View>(_ title: String, footer: String, @ViewBuilder tiles: () -> Tiles) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: UIText.localized(title).uppercased())
                .scaledFont(13)
                .tracking(0.2)
                .foregroundStyle(Theme.secondary)
                .scaledPadding(.horizontal, 32)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) { tiles() }
                .scaledPadding(.horizontal, 16)
            Text(ui: footer)
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.horizontal, 32)
        }
        .scaledPadding(.top, 24)
    }

    private func tile(sample: String, unit: String?, title: String, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: sample)
                        .scaledFont(30, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(Theme.primary)
                    if let unit {
                        Text(verbatim: unit).scaledFont(16, weight: .medium).foregroundStyle(Theme.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                HStack {
                    Text(ui: title).scaledFont(15, weight: .medium).foregroundStyle(Theme.primary)
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .scaledFont(18)
                        .foregroundStyle(selected ? Theme.accent : Theme.secondary.opacity(0.6))
                }
            }
            .scaledPadding(.all, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: SettingsStyle.radius - 6, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: SettingsStyle.radius - 6, style: .continuous)
                .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
