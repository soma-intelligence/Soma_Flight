import Foundation

/// Why an airport's flights run the way they do: the board's delays read against the weather impact.
/// Shared by the airport's issues card, the flight sheet's Good to Know and the Operations Report.
public enum DelayCause: Sendable, Hashable {
    /// Flights run late and the weather is likely slowing the airport.
    case weather(WeatherImpact)
    /// Flights run late but the weather is fine (or only a minor factor): the cause lies elsewhere.
    case notWeather(WeatherImpact)
    /// Flights are close to time, yet the weather could slow them.
    case weatherAhead(WeatherImpact)
    /// Flights are close to time and the weather is fine.
    case normal

    /// `delayed` is true when departures or arrivals run at moderate or major severity.
    public static func of(delayed: Bool, impact: WeatherImpact) -> DelayCause {
        switch (delayed, impact.slows) {
        case (true, true): .weather(impact)
        case (true, false): .notWeather(impact)
        case (false, true): .weatherAhead(impact)
        case (false, false): .normal
        }
    }

    public static func of(departures: DelayStats?, arrivals: DelayStats?, weather: Weather) -> DelayCause {
        let delayed = [departures, arrivals].contains { ($0?.severity ?? .normal) != .normal }
        return of(delayed: delayed, impact: .of(weather))
    }
}

/// Everything the Operations Report shows, worked out from the airport store's parts. Pure: the clock,
/// the time zone and the clock style are arguments, so previews and tests are stable.
public struct OpsReport: Sendable, Hashable {
    /// One board (departures or arrivals) read from the server's delay stats.
    public struct Board: Sendable, Hashable {
        public var departures: Bool
        public var avgDelayMinutes: Int
        public var total: Int
        public var late: Int
        public var canceled: Int
        public var severity: Severity
        public var trend: Trend?

        /// Share of flights 15 minutes or more late, 0...1.
        public var shareLate: Double { total == 0 ? 0 : Double(late) / Double(total) }
    }

    /// Share of late flights in the last two hours against earlier in the day.
    public struct Trend: Sendable, Hashable {
        public enum Direction: Sendable, Hashable { case worse, better, steady }
        public var recent: Double
        public var earlier: Double
        public var direction: Direction
    }

    /// One TAF period in plain words.
    public struct Period: Sendable, Hashable {
        /// "From 15:00", "At times 15:00 to 18:00", "30% chance 15:00 to 18:00".
        public var label: String
        public var category: FlightCategory
        public var text: String
        public var impact: WeatherImpact
        public var change: ForecastChange?
    }

    public var code: String
    public var summary: String
    public var departures: Board?
    public var arrivals: Board?
    public var impact: WeatherImpact?
    public var cause: DelayCause?
    /// "Low Clouds and Light Rain".
    public var conditionsTitle: String?
    public var conditionsText: String?
    public var periods: [Period]

    public init(code: String, stats: (departures: DelayStats, arrivals: DelayStats)?, weather: Weather?,
                timeZone: TimeZone, now: Date, clock: TimeStyle = .h24) {
        self.code = code
        departures = stats.map { Self.board($0.departures, departures: true, now: now) }
        arrivals = stats.map { Self.board($0.arrivals, departures: false, now: now) }
        impact = weather.map(WeatherImpact.of)
        cause = weather.map { DelayCause.of(departures: stats?.departures, arrivals: stats?.arrivals, weather: $0) }
        conditionsTitle = weather.map(Self.conditionsTitle)
        conditionsText = weather.map(Self.conditionsText)
        periods = weather.map { Self.periods($0, timeZone: timeZone, now: now, clock: clock) } ?? []
        summary = Self.summary(code: code, departures: departures, arrivals: arrivals, cause: cause,
                               weather: weather, timeZone: timeZone, now: now, clock: clock)
    }

    // MARK: Boards

    static func board(_ s: DelayStats, departures: Bool, now: Date) -> Board {
        Board(departures: departures, avgDelayMinutes: Int(s.avgDelayMinutes.rounded()), total: s.total,
              late: s.delayed15, canceled: s.canceled, severity: s.severity, trend: trend(s.perHour, now: now))
    }

    /// The last two hours (the hour under way and the one before) against the hours before them.
    /// Nil when either side has fewer than 4 flights: too few to call a trend.
    static func trend(_ hours: [HourBucket], now: Date) -> Trend? {
        let split = now.addingTimeInterval(-2 * 3600)
        let past = hours.filter { $0.hour <= now }
        func share(_ b: [HourBucket]) -> (Double, Int) {
            let late = b.reduce(0) { $0 + $1.late15 + $1.late45 }
            let all = b.reduce(0) { $0 + $1.onTime + $1.late15 + $1.late45 + $1.canceled + $1.diverted }
            return (all == 0 ? 0 : Double(late) / Double(all), all)
        }
        // A bucket counts as recent when any part of its hour falls in the last two hours.
        let (recent, nRecent) = share(past.filter { $0.hour.addingTimeInterval(3600) > split })
        let (earlier, nEarlier) = share(past.filter { $0.hour.addingTimeInterval(3600) <= split })
        guard nRecent >= 4, nEarlier >= 4 else { return nil }
        let direction: Trend.Direction = recent - earlier >= 0.1 ? .worse : (earlier - recent >= 0.1 ? .better : .steady)
        return Trend(recent: recent, earlier: earlier, direction: direction)
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    /// "Flights are leaving 29m late on average."
    static func delayHeadline(_ b: Board) -> String {
        let verb = b.departures ? "leaving" : "landing"
        guard b.total > 0 else { return "No \(b.departures ? "departures" : "arrivals") to count yet today." }
        if b.avgDelayMinutes < 5 { return "Flights are \(verb) on time on average." }
        return "Flights are \(verb) \(Format.minutes(b.avgDelayMinutes)) late on average."
    }

    /// "12 of 48 flights (25%) ran 15 minutes or more late. 2 canceled."
    static func delayDetail(_ b: Board) -> String {
        guard b.total > 0 else { return "The figures fill in as flights go." }
        var line = "\(b.late) of \(b.total) flights (\(percent(b.shareLate))) ran 15 minutes or more late."
        line += b.canceled == 0 ? " None canceled." : " \(b.canceled) canceled."
        return line
    }

    /// "Getting worse: 62% late in the last two hours, against 35% earlier today."
    static func trendLine(_ t: Trend) -> String {
        let figures = "\(percent(t.recent)) late in the last two hours, against \(percent(t.earlier)) earlier today."
        switch t.direction {
        case .worse: return "Getting worse: \(figures)"
        case .better: return "Easing: \(figures)"
        case .steady: return "Holding steady: \(figures)"
        }
    }

    // MARK: Current conditions

    /// "Low Clouds and Light Rain", "Thunderstorms with Heavy Rain", else the sky ("Mostly Cloudy").
    static func conditionsTitle(_ w: Weather) -> String {
        let wx = WeatherImpact.describe(w.presentWeather)
        let sky = Sky(metar: w.metarRaw)
        let base = wx.isEmpty ? sky.description : titleCase(wx)
        // Name a low ceiling too when the weather groups do not already explain it.
        if let ft = w.ceilingFt, ft < 1000, !wx.isEmpty, !wx.contains("fog") {
            return "Low Clouds\(base.contains(" and ") ? ", " : " and ")\(base)"
        }
        return base
    }

    /// Wind, visibility, clouds, temperature and pressure, one short sentence each.
    static func conditionsText(_ w: Weather) -> String {
        var parts: [String] = [windSentence(dir: w.windDirDeg, kt: w.windKt, gust: w.gustKt)]
        if let v = visibilitySentence(w.visibilitySm) { parts.append(v) }
        let wx = WeatherImpact.describe(w.presentWeather)
        if !wx.isEmpty { parts.append(capitalized(wx) + ".") }
        parts.append(cloudSentence(w.clouds ?? cloudLayers(in: w.metarRaw)))
        if let t = w.tempC {
            var s = "Temperature \(Int(t.rounded()))°C"
            if let d = w.dewpointC ?? dewpoint(in: w.metarRaw) { s += ", dew point \(Int(d.rounded()))°C" }
            parts.append(s + ".")
        }
        if let p = w.altimeterHpa ?? pressure(in: w.metarRaw) { parts.append("Pressure \(Int(p.rounded())) hPa.") }
        return parts.joined(separator: " ")
    }

    static func compass(_ deg: Int) -> String {
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        return names[((deg % 360 + 360) % 360 * 2 + 45) / 90 % 8]
    }

    static func kmh(_ kt: Int) -> Int { Int((Double(kt) * 1.852).rounded()) }

    /// "Wind from the south at 22 km/h, gusting to 41 km/h." Calm and variable winds say so.
    static func windSentence(dir: Int?, kt: Int?, gust: Int?) -> String {
        guard let kt else { return "Wind not reported." }
        if kt == 0 { return "Calm wind." }
        var s = dir.map { "Wind from the \(compass($0)) at \(kmh(kt)) km/h" } ?? "Variable wind at \(kmh(kt)) km/h"
        if let gust, gust > kt { s += ", gusting to \(kmh(gust)) km/h" }
        return s + "."
    }

    /// "Visibility 10 km or more." / "Visibility 2.4 km."
    static func visibilitySentence(_ sm: Double?) -> String? {
        guard let sm else { return nil }
        if sm >= 6 { return "Visibility 10 km or more." }
        let km = sm * 1.609
        return "Visibility \(km < 10 ? String(format: "%.1f", km) : String(Int(km.rounded()))) km."
    }

    static func coverName(_ cover: String) -> String? {
        switch cover {
        case "FEW": "few clouds"
        case "SCT": "scattered clouds"
        case "BKN": "broken clouds"
        case "OVC": "overcast"
        case "VV", "OVX": "sky hidden"
        default: nil
        }
    }

    static func feet(_ ft: Int) -> String {
        "\(ft.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))) ft"
    }

    /// "Broken clouds at 900 ft, overcast at 13,000 ft." or "Sky hidden, vertical visibility 100 ft."
    static func cloudSentence(_ layers: [CloudLayer]) -> String {
        let named = layers.compactMap { l -> String? in
            guard let name = coverName(l.cover), let ft = l.baseFt else { return nil }
            if name == "sky hidden" { return "\(name), vertical visibility \(feet(ft))" }
            return "\(name) at \(feet(ft))"
        }
        guard !named.isEmpty else { return "No cloud reported." }
        return capitalized(named.joined(separator: ", ")) + "."
    }

    /// Cloud groups of a METAR body (FEW040, BKN250, VV002), for payloads without `clouds`.
    static func cloudLayers(in report: String) -> [CloudLayer] {
        report.split(separator: " ").prefix { $0 != "RMK" && $0 != "TEMPO" && $0 != "BECMG" }.compactMap { t in
            guard let m = t.wholeMatch(of: /(FEW|SCT|BKN|OVC|VV)(\d{3})(?:CB|TCU)?/) else { return nil }
            return CloudLayer(cover: String(m.1), baseFt: Int(m.2).map { $0 * 100 })
        }
    }

    /// Dew point from the "22/20" or "M04/M06" group.
    static func dewpoint(in report: String) -> Double? {
        for t in report.split(separator: " ") {
            if let m = t.wholeMatch(of: /M?\d{2}\/(M?)(\d{2})/) { return (m.1.isEmpty ? 1 : -1) * (Double(m.2) ?? 0) }
        }
        return nil
    }

    /// Pressure in hPa from "Q1018" or "A2998" (inches of mercury).
    static func pressure(in report: String) -> Double? {
        for t in report.split(separator: " ") {
            if let m = t.wholeMatch(of: /Q(\d{4})/) { return Double(m.1) }
            if let m = t.wholeMatch(of: /A(\d{4})/), let inHg = Double(m.1) { return inHg / 100 * 33.8639 }
        }
        return nil
    }

    // MARK: Forecast

    /// The TAF periods still to come (or under way), in order, each in plain words. A TEMPO or PROB overlay
    /// follows the period it sits in when both start together.
    static func periods(_ w: Weather, timeZone: TimeZone, now: Date, clock: TimeStyle) -> [Period] {
        func overlay(_ p: ForecastPeriod) -> Int { p.change == .TEMPO || p.change == .PROB ? 1 : 0 }
        return w.forecast.filter { $0.to > now }
            .sorted { ($0.from, overlay($0), $0.to) < ($1.from, overlay($1), $1.to) }
            .map { p in
            Period(label: periodLabel(p, timeZone: timeZone, now: now, clock: clock), category: p.category,
                   text: periodText(p), impact: .of(p), change: p.change)
        }
    }

    /// "Fri 15:00" when the day differs from `now`'s, else "15:00".
    static func when(_ d: Date, timeZone: TimeZone, now: Date, clock: TimeStyle) -> String {
        let cal = AirportFacts.calendar(timeZone)
        let time = Format.clock(d, timeZone, clock)
        guard !cal.isDate(d, inSameDayAs: now) else { return time }
        let day = Date.FormatStyle(locale: Locale(identifier: "en_US"), timeZone: timeZone).weekday(.abbreviated)
        return "\(d.formatted(day)) \(time)"
    }

    static func periodLabel(_ p: ForecastPeriod, timeZone: TimeZone, now: Date, clock: TimeStyle) -> String {
        let from = p.from <= now ? "Now" : when(p.from, timeZone: timeZone, now: now, clock: clock)
        let to = when(p.to, timeZone: timeZone, now: now, clock: clock)
        switch p.change {
        case .TEMPO: return "At times, \(from.lowercasedFirstIfNow) to \(to)"
        case .PROB: return "\(p.probability.map { "\($0)%" } ?? "Some") chance, \(from.lowercasedFirstIfNow) to \(to)"
        case .BECMG: return p.from <= now ? "Changing now" : "Changing from \(from)"
        case .FM, nil: return p.from <= now ? "Now until \(to)" : "From \(from) until \(to)"
        }
    }

    /// "Wind from the east at 13 km/h. Visibility 10 km or more. Light rain. Overcast at 4,000 ft."
    static func periodText(_ p: ForecastPeriod) -> String {
        var parts: [String] = []
        if p.windKt != nil { parts.append(windSentence(dir: p.windDirDeg, kt: p.windKt, gust: p.gustKt)) }
        if let v = visibilitySentence(p.visibilitySm) { parts.append(v) }
        let wx = WeatherImpact.describe(p.wx ?? "")
        if !wx.isEmpty { parts.append(capitalized(wx) + ".") }
        if let clouds = p.clouds {
            parts.append(cloudSentence(clouds))
        } else if let ft = p.ceilingFt {
            parts.append("Cloud base \(feet(ft)).")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Summary

    /// One or two sentences: how late flights run, whether the weather is behind it, and weather to come.
    static func summary(code: String, departures: Board?, arrivals: Board?, cause: DelayCause?, weather: Weather?,
                        timeZone: TimeZone, now: Date, clock: TimeStyle) -> String {
        let late = [departures, arrivals].compactMap { $0 }.filter { $0.severity != .normal }
        let delays = late.map { "\($0.departures ? "departures" : "arrivals") by \(Format.minutes($0.avgDelayMinutes))" }
            .joined(separator: " and ")
        var first: String
        switch cause {
        case .weather(let i)?:
            first = "Flights at \(code) are running late, \(delays) on average. "
                + "\(capitalized(labels(i))) \(plural(i) ? "are" : "is") the likely cause, \(effect(i, continuous: true))."
        case .notWeather?:
            first = "Flights at \(code) are running late, \(delays) on average. The weather is fine, so the cause lies elsewhere."
        case .weatherAhead(let i)?:
            first = "Flights at \(code) are close to time for now, but \(labels(i)) could \(effect(i, continuous: false))."
        case .normal?:
            first = "Flights at \(code) are running close to time and the weather is fine."
        case nil:
            first = late.isEmpty ? "Flights at \(code) are running close to time."
                : "Flights at \(code) are running late, \(delays) on average."
        }
        if let next = upcoming(weather, now: now), let w = weather, !(WeatherImpact.of(w).slows) {
            let at = when(next.period.from, timeZone: timeZone, now: now, clock: clock)
            first += " Expect \(labels(next.impact)) from \(at)."
        }
        return first
    }

    /// The first period in the next 6 hours that would slow the airport, when the weather now does not.
    static func upcoming(_ w: Weather?, now: Date) -> (impact: WeatherImpact, period: ForecastPeriod)? {
        guard let w else { return nil }
        return w.forecast
            .filter { $0.from > now && $0.from <= now.addingTimeInterval(6 * 3600) }
            .sorted { $0.from < $1.from }
            .lazy.map { (WeatherImpact.of($0), $0) }
            .first { $0.0.slows }
    }

    /// "slowing arrivals" (continuous) or "slow arrivals"; severe weather holds flights up.
    static func effect(_ i: WeatherImpact, continuous: Bool) -> String {
        let side = switch i.affects {
        case .departures?: "departures"
        case .both?: "departures and arrivals"
        case .arrivals?, nil: "arrivals"
        }
        let verb = i.level == .severe ? (continuous ? "holding up" : "hold up") : (continuous ? "slowing" : "slow")
        return "\(verb) \(side)"
    }

    /// Whether the named hazards read as plural ("low clouds are", "fog is").
    static func plural(_ i: WeatherImpact) -> Bool {
        let named = i.hazards.filter { $0.level == i.level }
        return named.count > 1 || named.first.map { $0.label.hasSuffix("s") } ?? false
    }

    /// "low clouds and fog": the hazards behind a verdict.
    static func labels(_ i: WeatherImpact) -> String {
        let names = i.hazards.filter { $0.level == i.level }.prefix(2).map(\.label)
        return names.count == 2 ? "\(names[0]) and \(names[1])" : (names.first ?? "poor weather")
    }

    // MARK: Text helpers

    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
    static func lowercasedFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

    /// "light rain and mist" to "Light Rain and Mist".
    static func titleCase(_ s: String) -> String {
        let small: Set<String> = ["and", "with", "of", "to"]
        return s.split(separator: " ").enumerated().map { i, w in
            i > 0 && small.contains(String(w)) ? String(w) : w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
}

private extension String {
    /// "Now" reads "now" inside a sentence; clock times stay as they are.
    var lowercasedFirstIfNow: String { self == "Now" ? "now" : self }
}

// MARK: - Wording for the airport sheet and the flight sheet

extension AirportFacts {
    /// The issues card's line on the cause, nil without weather.
    static func causeLine(_ cause: DelayCause) -> String? {
        switch cause {
        case .weather(let i): "Likely weather related. \(i.reason)."
        case .notWeather(let i):
            i.level == .minor ? "Weather is not the main cause: only \(OpsReport.labels(i)) here."
                : "The weather is fine, so the delays have another cause."
        case .weatherAhead(let i): "Weather to watch. \(i.reason)."
        case .normal: nil
        }
    }

    /// The issues card's weather row: sky and temperature, then whether the weather explains the delays.
    static func issuesWeatherLine(_ w: Weather, departures: DelayStats, arrivals: DelayStats) -> String {
        let temp = w.tempC.map { ", \(Int($0.rounded()))°C" } ?? ""
        let sky = "\(Sky(metar: w.metarRaw).description)\(temp)."
        let cause = DelayCause.of(departures: departures, arrivals: arrivals, weather: w)
        return [sky, causeLine(cause)].compactMap { $0 }.joined(separator: " ")
    }
}

extension DetailFacts {
    /// The sentence Good to Know adds to a disruption row: whether that airport's weather is the cause.
    static func causeSentence(_ weather: Weather?, stats: DelayStats) -> String? {
        guard let weather else { return nil }
        switch DelayCause.of(delayed: stats.severity != .normal, impact: .of(weather)) {
        case .weather(let i): return "Likely weather related: \(OpsReport.labels(i))."
        case .notWeather: return "The weather there is fine, so it's not the cause."
        default: return nil
        }
    }

    /// Weather forecast at the arrival time that would slow arrivals: "Thunderstorms forecast around your 17:40
    /// arrival" with what it means. Nil when the TAF does not reach that far or the forecast is fine.
    static func arrivalWeather(_ weather: Weather?, arrival: Date?, timeZone: TimeZone,
                               clock: TimeStyle = .h24) -> (title: String, text: String)? {
        guard let weather, let arrival, let f = weather.forecastImpact(at: arrival), f.impact.slows else { return nil }
        let what = OpsReport.capitalized(OpsReport.labels(f.impact))
        let effect = f.impact.level == .severe ? "Arrivals may be held up, so allow extra time."
            : "Arrivals may be slowed, so allow extra time."
        let chance = switch f.period.change {
        case .TEMPO: " at times"
        case .PROB: f.period.probability.map { " (\($0)% chance)" } ?? " (possible)"
        default: ""
        }
        return ("Weather at arrival",
                "\(what) forecast\(chance) around your \(Format.clock(arrival, timeZone, clock)) arrival. \(effect)")
    }
}
