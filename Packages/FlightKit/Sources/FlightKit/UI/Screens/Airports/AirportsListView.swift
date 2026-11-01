import SwiftUI

/// Colours of an airport's status, the same on the globe and in the list.
public enum AirportStatusColor {
    public static func of(_ level: AirportStatusLevel) -> Color {
        switch level {
        case .normal: Theme.onTime
        case .minor: Theme.late
        case .major: Theme.veryLate
        }
    }
}

/// An airport's status as a dot in a soft ring of its own colour.
struct AirportStatusDot: View {
    var level: AirportStatusLevel
    var size: CGFloat = 12

    var body: some View {
        let color = AirportStatusColor.of(level)
        ZStack {
            Circle().fill(color.opacity(0.22)).frame(width: size * 2.4, height: size * 2.4)
            Circle().fill(color).frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

/// The calm note where live numbers would be, while the backend has no board provider.
struct DataPlanNote: View {
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .scaledFont(17, weight: .medium)
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Live airport stats need a data plan")
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                if !compact {
                    Text("On-time rates, delays and traffic come from a flight data provider we have not switched on yet. Weather and FAA programs below are live.")
                        .scaledFont(13.5)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .scaledPadding(.all, 14)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
        .accessibilityElement(children: .combine)
    }
}

/// The Airports list over the globe: the user's airports, then large hubs grouped by how they are doing,
/// filtered by region. A row opens the airport card. Each airport's dot on the globe is its status.
public struct AirportsListView: View {
    var store: AirportsListStore
    var onOpen: (String) -> Void
    var onClose: () -> Void
    var scrolls: Bool

    public init(store: AirportsListStore, onOpen: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.init(store: store, onOpen: onOpen, onClose: onClose, scrolls: true)
    }

    init(store: AirportsListStore, onOpen: @escaping (String) -> Void, onClose: @escaping () -> Void, scrolls: Bool) {
        self.store = store; self.onOpen = onOpen; self.onClose = onClose; self.scrolls = scrolls
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.top, 20)
            controls
                .scaledPadding(.top, 14)
                .scaledPadding(.bottom, 6)
            ScreenScroll(scrolls: scrolls, refresh: { await store.load() }) { content }
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Airports")
                .scaledFont(32, weight: .bold, relativeTo: .largeTitle)
                .foregroundStyle(Theme.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if scrolls {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                        .scaledFont(17, weight: .medium)
                        .foregroundStyle(Theme.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .roundGlass()
                .accessibilityLabel("Share")
            } else {
                RoundButton(systemImage: "square.and.arrow.up", label: "Share") {}
            }
            RoundButton(systemImage: "xmark", label: "Close", action: onClose)
        }
    }

    /// The list in a few lines: the airports with issues and their status.
    private var shareText: String {
        let issues = store.rows.filter { $0.status.level > .normal }
        guard !issues.isEmpty else { return "Airports running normally, from Soma Flight." }
        return "Airport issues now, from Soma Flight:\n" + issues.map {
            "\($0.airport.iata ?? $0.airport.id) \($0.airport.name): \($0.status.line ?? "")"
        }.joined(separator: "\n")
    }

    /// The time menu and the region pills, scrolling sideways; laid flat for snapshots (ImageRenderer draws
    /// neither a menu nor a scroll view).
    @ViewBuilder private var controls: some View {
        if scrolls {
            ScrollView(.horizontal, showsIndicators: false) { pills }
        } else {
            Color.clear.frame(height: 34).overlay(alignment: .leading) { pills.fixedSize() }.clipped()
        }
    }

    private var timeLabel: some View {
        HStack(spacing: 4) {
            Text(store.timeframe.title)
            Image(systemName: "chevron.down").scaledFont(11, weight: .semibold)
        }
        .scaledFont(15, weight: .semibold)
        .foregroundStyle(Theme.primary)
        .scaledPadding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().stroke(Theme.separator, lineWidth: 1))
    }

    private var pills: some View {
        @Bindable var store = store
        return HStack(spacing: 8) {
            if scrolls {
                Menu {
                    Picker("Time", selection: $store.timeframe) {
                        ForEach(AirportTimeframe.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("Later today and tomorrow arrive with the schedules feed")
                } label: { timeLabel }
                .accessibilityLabel("Time, \(store.timeframe.title)")
            } else {
                timeLabel
            }
            Rectangle().fill(Theme.separator).frame(width: 1, height: 20)
            ForEach(AirportRegionFilter.allCases, id: \.self) { region in
                let selected = store.region == region
                Button { withAnimation(.snappy) { store.region = region } } label: {
                    Text(region.title)
                        .scaledFont(15, weight: selected ? .semibold : .regular)
                        .foregroundStyle(selected ? Theme.primary : Theme.secondary)
                        .scaledPadding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Capsule().fill(selected ? Theme.pill : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .scaledPadding(.horizontal, Theme.gutter - 6)
    }

    @ViewBuilder private var content: some View {
        let sections = store.sections
        VStack(alignment: .leading, spacing: 0) {
            if let error = store.error {
                ErrorBanner(error: error, retry: { Task { await store.load() } })
                    .scaledPadding(.horizontal, 16).scaledPadding(.vertical, 8)
            }
            if !store.liveAvailable {
                DataPlanNote(compact: true)
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.top, 8)
            }
            if sections.isEmpty {
                if store.isLoading || store.loadedAt == nil {
                    ProgressView().frame(maxWidth: .infinity).scaledPadding(.vertical, 50)
                } else {
                    Text("No airports in this region yet.")
                        .scaledFont(15).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity).scaledPadding(.vertical, 50)
                }
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(Theme.primary)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle = section.subtitle {
                        Text(subtitle).scaledFont(13).foregroundStyle(Theme.secondary)
                    }
                }
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.top, 20)
                .scaledPadding(.bottom, 6)
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { i, row in
                    Button { onOpen(row.airport.id) } label: {
                        AirportListRowView(row: row, liveAvailable: store.liveAvailable)
                    }
                    .buttonStyle(.plain)
                    if i < section.rows.count - 1 {
                        Rectangle().fill(Theme.separator).frame(height: 1).scaledPadding(.leading, 76)
                    }
                }
            }
            Text("Weather from NOAA METARs and programs from the FAA, both public. Dots on the globe follow the list.")
                .scaledFont(12)
                .foregroundStyle(Theme.secondary)
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.top, 24)
                .scaledPadding(.bottom, 120)
        }
    }
}

/// One airport: its status dot and code, its name and status line, then the departure and arrival
/// columns (on time, average delay, canceled) or, without a board provider, its weather.
struct AirportListRowView: View {
    var row: AirportListRow
    var liveAvailable: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                AirportStatusDot(level: row.status.level)
                    .overlay(alignment: .bottomTrailing) {
                        if row.isFavorite {
                            Image(systemName: "star.fill")
                                .scaledFont(8, weight: .bold)
                                .foregroundStyle(Theme.primary)
                                .frame(width: 15, height: 15)
                                .background(Circle().fill(Theme.card))
                                .offset(x: 3, y: 3)
                        }
                    }
                Text(row.airport.iata ?? row.airport.id)
                    .scaledFont(12, weight: .semibold, design: .monospaced)
                    .foregroundStyle(Theme.secondary)
            }
            .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.airport.name)
                    .scaledFont(16.5, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(statusLine)
                    .scaledFont(13.5, weight: row.status.level > .normal ? .medium : .regular)
                    .foregroundStyle(row.status.level > .normal ? AirportStatusColor.of(row.status.level) : Theme.secondary)
                    .lineLimit(1)
                if liveAvailable, let live = row.live {
                    columns(live).scaledPadding(.top, 8)
                } else if let w = row.overview?.weather {
                    weather(w).scaledPadding(.top, 6)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(Theme.secondary.opacity(0.6))
                .scaledPadding(.top, 4)
        }
        .scaledPadding(.horizontal, Theme.gutter)
        .scaledPadding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// The status line, or the city and weather on a normal day.
    private var statusLine: String {
        if let line = row.status.line { return line }
        if let w = row.overview?.weather { return "\(row.airport.city) · \(w.condition)" }
        return row.airport.city
    }

    private func columns(_ live: AirportLiveSummary) -> some View {
        HStack(alignment: .top, spacing: 0) {
            column("On time", live, { $0.onTimePercent.map { "\($0)%" } ?? "-" })
            column("Avg delay", live, { Format.minutes($0.avgDelayMinutes) })
            column("Canceled", live, { $0.canceledPercent.map { "\($0)%" } ?? "-" })
        }
    }

    private func column(_ title: String, _ live: AirportLiveSummary, _ value: @escaping (AirportBrief) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).scaledFont(11.5, weight: .medium).foregroundStyle(Theme.secondary)
            ForEach([("airplane.departure", live.departures), ("airplane.arrival", live.arrivals)], id: \.0) { icon, brief in
                HStack(spacing: 5) {
                    Image(systemName: icon).scaledFont(10, weight: .semibold).foregroundStyle(Theme.secondary)
                    Text(brief.map(value) ?? "-").scaledFont(14, weight: .medium).foregroundStyle(Theme.primary)
                }
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func weather(_ w: AirportConditions) -> some View {
        HStack(spacing: 8) {
            Text(w.category.rawValue)
                .scaledFont(11, weight: .bold, design: .monospaced)
                .foregroundStyle(FlightCategoryColor.of(w.category))
                .scaledPadding(.horizontal, 6).scaledPadding(.vertical, 2)
                .background(Capsule().fill(FlightCategoryColor.of(w.category).opacity(0.16)))
            if let t = w.tempC {
                Text("\(Int(t.rounded()))°").scaledFont(13.5, weight: .medium).foregroundStyle(Theme.primary)
            }
            if let wind = w.windKt {
                Text(w.gustKt.map { "\(wind)G\($0) kt" } ?? "\(wind) kt")
                    .scaledFont(13.5).foregroundStyle(Theme.secondary)
            }
        }
        .monospacedDigit()
    }
}

/// The usual colours of the flight categories (VFR green, MVFR blue, IFR red, LIFR magenta).
enum FlightCategoryColor {
    static func of(_ c: FlightCategory) -> Color {
        switch c {
        case .VFR: Theme.vfr
        case .MVFR: Theme.mvfr
        case .IFR: Theme.ifr
        case .LIFR: Theme.lifr
        }
    }
}

/// The map's round glass button that opens the Airports list. SF Symbols has no control tower, so the
/// tower's radio stands in for it.
public struct AirportsMapButton: View {
    var action: () -> Void

    public init(action: @escaping () -> Void) { self.action = action }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Airports")
    }
}
