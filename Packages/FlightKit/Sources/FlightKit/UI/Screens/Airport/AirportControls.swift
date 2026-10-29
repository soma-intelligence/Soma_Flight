import SwiftUI

/// Text segments where the chosen one sits in a grey capsule (Departures / Arrivals / Totals).
struct PillPicker<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    Text(label)
                        .scaledFont(14, weight: .medium)
                        .foregroundStyle(value == selection ? Theme.primary : Theme.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(value == selection ? Theme.pill : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(value == selection ? .isSelected : [])
            }
        }
    }
}

/// Grey capsule with an optional icon, a title and a chevron, opening a menu of choices.
struct FilterPill<Value: Hashable>: View {
    var icon: String?
    var title: String
    var options: [(Value, String)]
    @Binding var selection: Value
    @Environment(\.airportStaticControls) private var staticControls

    var body: some View {
        if staticControls {
            label
        } else {
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                }
            } label: { label }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).scaledFont(13, weight: .medium) }
            Text(title).scaledFont(14, weight: .medium).lineLimit(1)
            Image(systemName: "chevron.down").scaledFont(11, weight: .semibold).foregroundStyle(Theme.secondary)
        }
        .foregroundStyle(Theme.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.pill))
        .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 0.5))
        .contentShape(Capsule())
    }
}

/// Stale badge for one section, shown only once its data is older than `ttl`.
struct SectionFreshness: View {
    var fetchedAt: Date?
    var ttl: Duration
    var now: Date

    var body: some View {
        if let fetchedAt, now.timeIntervalSince(fetchedAt) > Double(ttl.components.seconds) {
            StaleBadge(fetchedAt: fetchedAt, ttl: ttl, now: now)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StaticControlsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Draw menus as their labels only. ImageRenderer cannot draw native menu buttons, so the
    /// snapshot tests set this.
    var airportStaticControls: Bool {
        get { self[StaticControlsKey.self] }
        set { self[StaticControlsKey.self] = newValue }
    }
}
