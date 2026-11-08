import SwiftUI

// MARK: CO2

/// The full Passport's CO2 section: the period's total for one passenger and the average per flight.
struct PassportEmissionsSection: View {
    var kilograms: Double
    var flights: Int

    var body: some View {
        PassportSection(title: EmissionsFacts.title) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: EmissionsFacts.amount(kilograms))
                        .scaledFont(46, weight: .bold)
                        .monospacedDigit()
                        .foregroundStyle(Theme.primary)
                    Text("CO2e").scaledFont(24).foregroundStyle(Theme.secondary)
                }
                if flights > 0 {
                    Text(verbatim: String(localized: "About \(EmissionsFacts.amount(kilograms / Double(flights))) per flight",
                                          bundle: .main))
                        .scaledFont(16)
                        .monospacedDigit()
                        .foregroundStyle(Theme.primary)
                        .scaledPadding(.top, 4)
                }
                Text("For one passenger, in the seat class you noted (economy when none), non-CO2 effects included.")
                    .scaledFont(14)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaledPadding(.top, 10)
                Text(ui: EmissionsFacts.source)
                    .scaledFont(14)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Schengen

/// 90 days as a bar, filled up to the days used.
struct SchengenMeter: View {
    var used: Int

    var body: some View {
        GeometryReader { geo in
            let share = min(Double(used) / Double(Schengen.maxDays), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.pill)
                Capsule().fill(used > Schengen.maxDays ? Color.red : Theme.passportAccent)
                    .frame(width: geo.size.width * share)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// The detail: the count, the 180-day window it covers, the last day of stay, every stay that falls in the
/// window, and what the count cannot see.
struct SchengenDetailSheet: View {
    var summary: Schengen.Summary
    @Environment(\.dismiss) private var dismiss

    private var inWindow: [Schengen.Stay] {
        summary.stays.filter { ($0.exit ?? summary.day) >= summary.windowStart }.reversed()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: SchengenFacts.used(summary))
                            .scaledFont(28, weight: .bold)
                            .monospacedDigit()
                        SchengenMeter(used: summary.used)
                        Text(verbatim: SchengenFacts.until(summary))
                            .scaledFont(17, weight: .semibold)
                    }
                    .scaledPadding(.vertical, 6)
                    LabeledContent("180-day window") {
                        Text(verbatim: SchengenFacts.window(summary))
                    }
                    LabeledContent("Days left") {
                        Text(verbatim: "\(summary.remaining)")
                    }
                }
                Section("Stays in the window") {
                    if inWindow.isEmpty {
                        Text("None in the last 180 days").foregroundStyle(Theme.secondary)
                    }
                    ForEach(inWindow, id: \.self) { s in
                        Text(verbatim: SchengenFacts.stay(s, through: summary.day))
                    }
                }
                Section {
                    Text(ui: SchengenFacts.caveat)
                        .scaledFont(14)
                        .foregroundStyle(Theme.secondary)
                } footer: {
                    Text("Entry and exit days both count. Every 180-day window may hold 90 days at most.")
                }
            }
            .navigationTitle(Text(ui: SchengenFacts.title))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
