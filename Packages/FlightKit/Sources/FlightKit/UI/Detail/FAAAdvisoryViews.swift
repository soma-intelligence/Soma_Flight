import SwiftUI

/// One FAA row of Good to Know or the issues card: a program ("Ground delay program at SFO") or the
/// NOTAM line ("2 runway closures at SFO").
struct AdvisoryRowData: Hashable {
    var symbol: String
    var title: String
    var text: String
    var severity: Severity
}

/// The FAA rows of each end of a flight, for Good to Know.
struct FlightAdvisoryRows: Hashable {
    var origin: [AdvisoryRowData] = []
    var destination: [AdvisoryRowData] = []
}

extension FAAFacts {
    /// The SF Symbol of a program.
    static func symbol(_ k: AirportProgram.Kind) -> String {
        switch k {
        case .closure: "xmark.octagon.fill"
        case .groundStop: "hand.raised.fill"
        case .groundDelay: "hourglass"
        case .departureDelay: "airplane.departure"
        case .arrivalDelay: "airplane.arrival"
        case .deicing: "snowflake"
        }
    }

    /// The FAA rows of one airport: its programs that matter at that end, then the NOTAM line.
    static func rows(programs: AirportPrograms?, notams: NotamReport?, end: End?, code: String,
                     timeZone: TimeZone, clock: TimeStyle, now: Date) -> [AdvisoryRowData] {
        var out = Self.programs(programs, at: end, now: now).map { p in
            let r = row(p, code: code, timeZone: timeZone, clock: clock, now: now)
            return AdvisoryRowData(symbol: symbol(p.kind), title: r.title, text: r.text, severity: p.severity)
        }
        if let n = notamLine(notams, code: code) {
            let closed = notams?.notams.contains(where: \.closesAirport) == true
            out.append(AdvisoryRowData(symbol: closed ? "xmark.octagon.fill" : "road.lanes", title: n.title,
                                       text: n.text, severity: closed ? .major : .moderate))
        }
        return out
    }

    /// The airport sheet's FAA rows: every program, then the NOTAM line.
    static func airportRows(programs: AirportPrograms?, notams: NotamReport?, code: String, timeZone: TimeZone,
                            clock: TimeStyle, now: Date) -> [AdvisoryRowData] {
        rows(programs: programs, notams: notams, end: nil, code: code, timeZone: timeZone, clock: clock, now: now)
    }

    /// How bad the airport's day is: the worse of its boards and its FAA rows.
    static func issuesSeverity(stats: (departures: DelayStats, arrivals: DelayStats)?,
                               rows: [AdvisoryRowData]) -> Severity {
        var s = stats.map { AirportFacts.worst($0.departures.severity, $0.arrivals.severity) } ?? .normal
        for r in rows { s = AirportFacts.worst(s, r.severity) }
        return s
    }

    /// The issues card's title: the FAA's word when it closed the airport or stopped flights, else the
    /// boards' ("Heavy delays today", "Delays are building").
    static func issuesTitle(_ s: Severity, programs: [AdvisoryRowData]) -> String {
        if programs.contains(where: { $0.symbol == symbol(.closure) }) { return "Airport closed" }
        if programs.contains(where: { $0.symbol == symbol(.groundStop) }) { return "Flights held by the FAA" }
        return AirportFacts.issuesTitle(s)
    }

    /// Good to Know's FAA rows for a flight: none for a Passport flight or once it landed.
    @MainActor static func rows(_ store: FlightDetailStore, flight f: Flight, clock: TimeStyle,
                                now: Date) -> FlightAdvisoryRows {
        guard !store.isArchived, worthLoading(f.status) else { return FlightAdvisoryRows() }
        let a = store.advisories
        let destCode = store.destination.map { $0.iata ?? $0.id } ?? f.destinationCode
        return FlightAdvisoryRows(
            origin: rows(programs: a.originPrograms, notams: a.originNotams, end: .origin, code: f.originCode,
                         timeZone: store.origin?.timeZone ?? .current, clock: clock, now: now),
            destination: rows(programs: a.destinationPrograms, notams: a.destinationNotams, end: .destination,
                              code: destCode, timeZone: store.destination?.timeZone ?? .current, clock: clock,
                              now: now))
    }
}

/// An FAA row inside an airport's Good to Know card: tinted icon and title, grey line, a chevron to the
/// airport sheet (where the Operations Report has the details).
struct AdvisoryRow: View {
    var data: AdvisoryRowData
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            InfoRow(symbol: data.symbol, tint: tint, title: data.title, titleTint: tint, text: data.text,
                    chevron: true)
                .scaledPadding(.all, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the airport")
    }

    private var tint: Color { data.severity == .major ? Theme.veryLate : Theme.late }
}

// MARK: - Operations Report

/// The report's FAA sections: the programs in force, then the decoded NOTAMs with the text as published
/// under each. Nothing when the airport has neither.
struct FAAReportSections: View {
    var programs: AirportPrograms?
    var notams: NotamReport?
    var code: String
    var timeZone: TimeZone
    var clock: TimeStyle
    var now: Date

    var body: some View {
        if let programs {
            BriefSection(symbol: "hand.raised", title: "FAA Programs") {
                if programs.programs.isEmpty {
                    BriefItem(title: "No Programs", text: "The FAA has no ground stop, delay program or closure at \(code) right now.",
                              source: FAAFacts.programsSource(programs, now: now))
                } else {
                    ForEach(programs.programs) { p in
                        let r = FAAFacts.row(p, code: code, timeZone: timeZone, clock: clock, now: now)
                        VStack(alignment: .leading, spacing: 0) {
                            BriefItem(title: r.title, tint: p.severity == .major ? Theme.veryLate : Theme.late,
                                      text: r.text, source: FAAFacts.programsSource(programs, now: now))
                            if let raw = p.reasonRaw { RawReport(text: "FAA reason: \(raw)") }
                        }
                    }
                }
            }
        }
        if let notams, !notams.notams.isEmpty {
            BriefSection(symbol: "road.lanes", title: "NOTAMs") {
                ForEach(notams.notams) { n in
                    VStack(alignment: .leading, spacing: 0) {
                        BriefItem(title: n.title, tint: n.relevance >= 80 ? Theme.late : nil,
                                  text: [n.detail, FAAFacts.notamWindow(n, timeZone: timeZone, clock: clock, now: now)]
                                      .compactMap { $0 }.joined(separator: " "),
                                  source: "NOTAM \(n.number)")
                        RawReport(text: n.raw)
                    }
                }
                SourceLine(text: FAAFacts.notamSource(notams, now: now))
            }
        }
    }
}

/// The issues card's FAA rows, in its own style.
struct IssuesProgramRows: View {
    var rows: [AdvisoryRowData]

    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
            if i > 0 { Rectangle().fill(Theme.primary.opacity(0.12)).frame(height: 1).scaledPadding(.leading, 30) }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: r.symbol)
                    .scaledFont(15, weight: .medium)
                    .foregroundStyle(Theme.primary)
                    .frame(width: 20)
                    .scaledPadding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ui: r.title).scaledFont(15.5, weight: .medium).foregroundStyle(Theme.primary)
                    Text(ui: r.text)
                        .scaledFont(14.5)
                        .foregroundStyle(Theme.primary.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scaledPadding(.vertical, 10)
        }
    }
}

#if DEBUG
// MARK: - Previews

#Preview("Good to Know: SFO program and NOTAMs") {
    let now = Date(timeIntervalSince1970: 1_793_500_000)
    let tz = TimeZone(identifier: "America/Los_Angeles")!
    let programs = AirportPrograms(airportIcao: "KSFO", iata: "SFO", fetchedAt: now,
                                   programs: FakeFAAService.programs("KSFO", now: now))
    let notams = NotamReport(airportIcao: "KSFO", iata: "SFO", fetchedAt: now,
                             notams: FakeFAAService.notams("KSFO", now: now))
    let rows = FAAFacts.rows(programs: programs, notams: notams, end: .destination, code: "SFO", timeZone: tz,
                             clock: .h24, now: now)
    return ScrollView {
        DetailCard(padded: false) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if i > 0 { Hairline() }
                AdvisoryRow(data: r) {}
            }
        }
        .padding()
        FAAReportSections(programs: programs, notams: notams, code: "SFO", timeZone: tz, clock: .h24, now: now)
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
#endif
