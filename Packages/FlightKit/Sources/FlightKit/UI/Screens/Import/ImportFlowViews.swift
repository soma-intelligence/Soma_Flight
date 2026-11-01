import SwiftUI

// The Import screen's steps after a file is read: what it holds (the summary card and the rows left
// out), the import running, and what it did.

/// Four figures in a card: rows found, new flights, duplicates, rows that could not be read.
struct ImportReviewSummary: View {
    var review: ImportStore.Review

    var body: some View {
        DetailCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(review.title)
                    .scaledFont(15, weight: .medium)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                HStack(alignment: .top, spacing: 8) {
                    ImportFigure(value: review.found, label: review.source == .email || review.source == .calendar ? "Found" : "Rows")
                    ImportFigure(value: review.past.count + review.upcoming.count, label: "New", tint: Theme.accent)
                    ImportFigure(value: review.duplicates.count, label: "Already in")
                    ImportFigure(value: review.unreadable.count, label: "Can't read",
                                 tint: review.unreadable.isEmpty ? nil : Theme.late)
                }
                if let m = review.method {
                    Text(m == .structured ? "Found in the email's booking details." : "Found in the email's text.")
                        .scaledFont(13).foregroundStyle(Theme.secondary)
                }
            }
        }
        .scaledPadding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

/// A big number over a small grey label.
struct ImportFigure: View {
    var value: Int
    var label: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .scaledFont(28, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(tint ?? Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label.uppercased())
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A group of rows under a header that opens and closes: the rows left out, the flights not added.
struct ImportDisclosure<Item: Identifiable, Row: View>: View {
    var title: String
    var items: [Item]
    var startsOpen = false
    @ViewBuilder var row: (Item) -> Row
    @State private var open: Bool?

    var body: some View {
        if !items.isEmpty {
            let isOpen = open ?? startsOpen
            Button {
                withAnimation(.snappy(duration: 0.25)) { open = !isOpen }
            } label: {
                HStack(spacing: 8) {
                    Text(title.uppercased())
                    Text(items.count.formatted()).monospacedDigit()
                    Spacer()
                    Image(systemName: "chevron.down")
                        .scaledFont(12, weight: .semibold)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .scaledPadding(.horizontal, 20)
                .scaledPadding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityHint(isOpen ? "Hides these rows" : "Shows these rows")
            .scaledPadding(.top, 14)
            if isOpen {
                ForEach(items) { item in
                    Hairline()
                    row(item)
                }
            }
        }
    }
}

/// "Row 12   Departure “XYZ1” is not an airport code".
struct ImportReasonRow: View {
    var label: String
    var reason: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if !label.isEmpty {
                Text(label).scaledFont(15, weight: .medium).monospacedDigit().foregroundStyle(Theme.secondary)
                    .fixedSize()
            }
            Text(reason).scaledFont(15).foregroundStyle(Theme.primary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .scaledPadding(.horizontal, 20)
        .scaledPadding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

/// The import running: "Importing 120 of 300", a bar that fills a batch at a time.
struct ImportProgressPanel: View {
    var progress: HistoryImport.Progress

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.down.to.line.circle.fill")
                .scaledFont(52)
                .foregroundStyle(Theme.accent)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Importing \(progress.done.formatted()) of \(progress.total.formatted())")
                    .scaledFont(22, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(Theme.primary)
                    .contentTransition(.numericText())
                Text("Saving your flights to your Passport.")
                    .scaledFont(15)
                    .foregroundStyle(Theme.secondary)
            }
            ImportBar(fraction: progress.fraction)
                .animation(.easeOut(duration: 0.35), value: progress.done)
                .scaledPadding(.horizontal, 8)
            Text("You can close this screen or leave the app. The import keeps going, and you'll get a notification when it's done.")
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .scaledPadding(.horizontal, 28)
        .scaledPadding(.top, 48)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Importing \(progress.done) of \(progress.total) flights")
    }
}

/// A thick rounded bar that fills left to right.
struct ImportBar: View {
    var fraction: Double
    @ScaledMetric(relativeTo: .body) private var height = 8

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.pill)
                Capsule().fill(Theme.accent).frame(width: max(height, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Import progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

/// What the import did: the headline, the figures, the flights that did not go in and why (with a retry),
/// and what happened to the upcoming ones.
struct ImportResultPanel: View {
    var summary: ImportStore.Summary
    var lookup: (String) -> Airport?
    var retry: () -> Void

    private var failedCount: Int { summary.addFailures.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .scaledFont(52)
                    .foregroundStyle(failedCount == 0 ? Theme.onTime : Theme.late)
                    .symbolEffect(.bounce, value: summary.added)
                    .accessibilityHidden(true)
                Text(summary.headline)
                    .scaledFont(22, weight: .bold)
                    .foregroundStyle(Theme.primary)
                    .multilineTextAlignment(.center)
                if summary.stopped {
                    Text("You stopped the import. The flights saved before stay in your Passport.")
                        .scaledFont(15).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .scaledPadding(.top, 24)
            .scaledPadding(.bottom, 20)
            .scaledPadding(.horizontal, 20)

            DetailCard {
                HStack(alignment: .top, spacing: 8) {
                    ImportFigure(value: summary.added, label: "Imported", tint: summary.added > 0 ? Theme.onTime : nil)
                    if !summary.followed.isEmpty || summary.later > 0 {
                        ImportFigure(value: summary.followed.count + summary.later, label: "Followed")
                    }
                    ImportFigure(value: summary.skipped, label: "Skipped")
                    ImportFigure(value: failedCount, label: "Failed", tint: failedCount > 0 ? Theme.veryLate : nil)
                }
            }
            .scaledPadding(.horizontal, 16)

            if let extra = followLine {
                Text(extra)
                    .scaledFont(15)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaledPadding(.horizontal, 20)
                    .scaledPadding(.top, 14)
            }

            if failedCount > 0 {
                Button(action: retry) {
                    Label(failedCount == 1 ? "Retry 1 Flight" : "Retry \(failedCount.formatted()) Flights",
                          systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .scaledFont(16, weight: .semibold)
                .scaledPadding(.horizontal, 20)
                .scaledPadding(.top, 18)

                ImportDisclosure(title: "Not added", items: summary.addFailures, startsOpen: failedCount <= 20) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.line(f.flight, lookup: lookup))
                            .scaledFont(15, weight: .medium).foregroundStyle(Theme.primary)
                        Text(f.label.isEmpty ? f.reason : "\(f.label) \u{00B7} \(f.reason)")
                            .scaledFont(13).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaledPadding(.horizontal, 20)
                    .scaledPadding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Follows and the waiting list, in words ("Following AF 84. 2 flights will be followed ...").
    private var followLine: String? {
        var s = summary
        s.added = 0
        s.addFailures = []
        s.addError = nil
        let text = s.message
        return text == "Nothing was added." ? nil : text
    }

    /// "AF 84  SFO → CDG  14 Mar 2025".
    static func line(_ f: PastFlight, lookup: (String) -> Airport?) -> String {
        let o = lookup(f.originIcao), d = lookup(f.destinationIcao)
        var parts: [String] = []
        if !f.ident.isEmpty { parts.append(Format.ident(f.ident)) }
        parts.append("\(o?.iata ?? f.originIcao) \u{2192} \(d?.iata ?? f.destinationIcao)")
        parts.append(ScreenFormat.day(f.date, o?.timeZone ?? .gmt))
        return parts.joined(separator: "  ")
    }
}

/// A capsule over the app when an import ends while its screen is closed. It goes after a few seconds
/// or on a tap.
struct ImportToast: View {
    var text: String
    var dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.onTime).accessibilityHidden(true)
                Text(text)
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scaledPadding(.horizontal, 18)
            .scaledPadding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.top, 8)
        .task {
            try? await Task.sleep(for: .seconds(5))
            dismiss()
        }
        .accessibilityLabel(text)
        .accessibilityHint("Dismisses")
    }
}
