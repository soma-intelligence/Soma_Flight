import FlightWatchKit
import SwiftUI

/// One flight on the wrist: the big status in its colour, both ends with their times (the schedule struck
/// through once it moved), the progress while in the air, the gate, terminal, belt and seat, and the
/// boarding pass barcode when the phone keeps one.
struct WatchFlightScreen: View {
    let model: WatchFlightsModel
    let id: UUID

    var body: some View {
        TimelineView(.everyMinute) { context in
            if let detail = model.detail(for: id, at: context.date) {
                content(detail)
            } else {
                ContentUnavailableView("Flight not on iPhone", systemImage: "airplane",
                                       description: Text("It is no longer in My Flights."))
            }
        }
    }

    private func content(_ d: WatchFlightDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(d)
                WatchEndRow(end: d.departure, word: "Departs")
                if let progress = d.progress {
                    WatchProgress(progress: progress, color: ActivityPalette.color(d.level), left: d.timeLeft)
                }
                WatchEndRow(end: d.arrival, word: "Arrives")
                if !d.facts.isEmpty { WatchFacts(facts: d.facts) }
                if let pass = d.pass {
                    NavigationLink {
                        WatchPassScreen(pass: pass, ident: d.ident)
                    } label: {
                        Label("Boarding Pass", systemImage: "qrcode")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .tint(ActivityPalette.pill)
                }
            }
        }
        .navigationTitle(d.ident)
        .containerBackground(ActivityPalette.color(d.level).gradient.opacity(0.35), for: .navigation)
    }

    private func header(_ d: WatchFlightDetail) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(d.display.routeCodes)
                .font(.headline)
                .foregroundStyle(ActivityPalette.secondary)
            Text(d.status)
                .font(.system(.title2, weight: .bold))
                // The flight card's rule: white on time, the level's colour otherwise, red when canceled.
                .foregroundStyle(d.level == .onTime ? ActivityPalette.primary
                                 : d.level == .canceled ? ActivityPalette.veryLate : ActivityPalette.color(d.level))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(d.countdownLine)
                .font(.footnote)
                .foregroundStyle(ActivityPalette.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(d.spokenHeader)
    }
}

/// One end: the code and city, the best time in its colour, the schedule struck through beside it.
struct WatchEndRow: View {
    let end: WatchFlightDetail.End
    let word: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                Text(end.code).font(.system(.title3, weight: .semibold))
                Text(end.city).font(.caption2).foregroundStyle(ActivityPalette.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(end.time)
                        .font(.system(.title3, weight: .semibold).monospacedDigit())
                        .foregroundStyle(WatchTone.color(end.tone))
                    if let mark = end.dayMark {
                        Text(mark).font(.caption2).foregroundStyle(ActivityPalette.secondary)
                    }
                }
                if let scheduled = end.scheduled {
                    Text(scheduled)
                        .font(.caption2.monospacedDigit())
                        .strikethrough()
                        .foregroundStyle(ActivityPalette.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        var s = "\(word) \(end.city) at \(end.time)"
        if let offset = end.offset { s += ", \(offset)" }
        if let scheduled = end.scheduled { s += ", scheduled \(scheduled)" }
        return s
    }
}

/// The share flown, with the plane on the line, and the time left.
struct WatchProgress: View {
    let progress: Double
    let color: Color
    let left: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let x = geo.size.width * progress
                ZStack(alignment: .leading) {
                    Capsule().fill(ActivityPalette.track).frame(height: 4)
                    Capsule().fill(color).frame(width: max(4, x), height: 4)
                    Image(systemName: "airplane")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ActivityPalette.primary)
                        .position(x: min(max(7, x), geo.size.width - 7), y: geo.size.height / 2)
                }
            }
            .frame(height: 14)
            if let left {
                Text(left).font(.caption2).foregroundStyle(ActivityPalette.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int((progress * 100).rounded())) percent flown" + (left.map { ", \($0)" } ?? ""))
    }
}

/// The gate (the app's yellow badge), terminal, belt and seat, two to a row.
struct WatchFacts: View {
    let facts: [WatchFlightDetail.Fact]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 8) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 1) {
                    Text(fact.label.uppercased())
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(ActivityPalette.secondary)
                    if fact.isGate {
                        Text(fact.value)
                            .font(.system(.headline, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .background(ActivityPalette.gate, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        Text(fact.value).font(.headline)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(fact.label) \(fact.value)")
            }
        }
    }
}

#Preview("In the air") {
    let model = WatchFlightsModel(defaults: UserDefaults(suiteName: "preview.detail")!)
    let snapshot = WatchSnapshot.preview()
    model.receive(snapshot)
    return NavigationStack { WatchFlightScreen(model: model, id: snapshot.flights.flights[0].id) }
}

#Preview("Before departure, with a pass") {
    let model = WatchFlightsModel(defaults: UserDefaults(suiteName: "preview.detail.pass")!)
    let snapshot = WatchSnapshot.preview()
    model.receive(snapshot)
    return NavigationStack { WatchFlightScreen(model: model, id: snapshot.flights.flights[1].id) }
}
