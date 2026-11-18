import SwiftUI

/// One followed flight in full: the airline, flight number and route pinned at the top (the Detail header,
/// R5); then the hero status card (R3: the headline in the delay colour, the airline and time left, the route
/// progress, both gates, boarding, the belt), departure and arrival with their gates, the booking
/// code and seat tiles, the boarding pass, Good to Know, the arrival forecast and where the plane is (paid data, when
/// insights are on), the detailed timetable, the airline, the user's
/// history on the route, every update, the notes and a link to report a data issue. A glass action bar
/// (R4) holds More, Alerts and Share, and the content ends above it. The map arc and live plane
/// belong to the shell.
public struct FlightDetailView: View {
    var store: FlightDetailStore
    var onAirport: (String) -> Void
    var onClose: (() -> Void)?
    var onStopTracking: ((Flight.ID) async -> APIError?)?
    var fixedNow: Date?
    var scrolls: Bool
    @State private var editing: DetailField?
    @State private var pasteHint: String?
    @State private var pasteFailures = 0
    @Environment(\.reference) private var reference
    @Environment(\.units) private var units
    @Environment(\.openURL) private var openURL
    @Environment(\.flightSharing) private var sharingService
    @Environment(\.flightTexts) private var flightTexts
    @Environment(\.travelJournal) private var travelJournal
    @Environment(\.requestSignIn) private var requestSignIn
    @Environment(\.stopFollowing) private var stopFollowing
    @Environment(\.scenePhase) private var scenePhase
    /// "Stop following AF 84?" when no Undo is on offer (`stopFollowing` not wired or the flight not listed).
    @State private var confirmingStop = false
    /// The system drops this app's alerts (E5): the bell shows off and opens Settings.
    @State private var alertsDenied = false
    @State private var askingSettings = false
    /// The flight's live link (made on Share, stopped from the menu); nil for Passport flights.
    @State private var sharing: FlightShareModel?
    /// The route-derived cards (sun, landmarks, window side), worked out once per route and seat rather than on
    /// every render: a long-haul route costs tens of milliseconds, and the sheet renders on every frame while
    /// it moves.
    @State private var routeCache = RouteFactsCache()

    /// - Parameters:
    ///   - onAirport: opens the airport sheet for an ICAO code.
    ///   - onClose: closes the sheet; nil hides the close button.
    ///   - onStopTracking: unfollows the flight through the shell's list and returns the error, nil on
    ///     success; when nil the store asks the service. The sheet closes (`onClose`) once it worked.
    ///   - now: a fixed clock for previews; nil follows the real time.
    public init(store: FlightDetailStore, onAirport: @escaping (String) -> Void, onClose: (() -> Void)? = nil,
                onStopTracking: ((Flight.ID) async -> APIError?)? = nil, now: Date? = nil) {
        self.init(store: store, onAirport: onAirport, onClose: onClose, onStopTracking: onStopTracking,
                  now: now, scrolls: true)
    }

    init(store: FlightDetailStore, onAirport: @escaping (String) -> Void, onClose: (() -> Void)? = nil,
         onStopTracking: ((Flight.ID) async -> APIError?)? = nil, now: Date?, scrolls: Bool) {
        self.store = store; self.onAirport = onAirport; self.onClose = onClose
        self.onStopTracking = onStopTracking; self.fixedNow = now; self.scrolls = scrolls
    }

    public var body: some View {
        ClockView(fixed: fixedNow) { now in
            VStack(spacing: 0) {
                if store.isGone, !store.isArchived {
                    // The server no longer has this flight (I7): nothing to retry, only Close.
                    if let onClose {
                        HStack { Spacer(); CloseButton(action: onClose) }
                    }
                    FlightGoneState(onClose: onClose)
                } else if let flight = store.flight {
                    DetailHeader(flight: flight, origin: store.origin, destination: plannedDestination(flight),
                                 airline: airline(flight), onClose: onClose,
                                 actions: Self.barInHeader ? AnyView(bottomBar(flight)) : nil)
                        .scaledPadding(.top, 10)
                        .scaledPadding(.bottom, 4)
                    ScrollViewReader { proxy in
                        ScreenScroll(scrolls: scrolls) { sections(flight, now: now) }
                            .defaultScrollAnchor(Self.startAnchor)
                            .task(id: store.routeHistory != nil) { await jumpForScreenshots(proxy) }
                    }
                } else {
                    if let onClose {
                        HStack { Spacer(); CloseButton(action: onClose) }
                    }
                    if let error = store.error {
                        ErrorBanner(error: error, hasContent: false, retry: reload, signIn: signIn)
                            .scaledPadding(.all, Theme.Space.md)
                        Spacer(minLength: 0)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(Theme.background)
        // The glass action bar (R4), pinned above the home indicator; the content pads itself to end above it.
        .detailActionBar(shown: store.flight != nil && !Self.barInHeader && barShown) {
            if let flight = store.flight { actionBar(flight) }
        }
        // Only the flip is state: a height written every frame of a drag re-ran the whole page.
        .onGeometryChange(for: Bool.self) { Self.showsBar(height: $0.size.height) } action: { shown in
            withAnimation(.snappy) { barShown = shown }
        }
        // The Mac shows the editors as popovers on their tile (`detailEditor`); iOS as sheets.
        .sheet(item: Self.barInHeader ? .constant(nil) : $editing) { field in
            Group {
                if field == .notes {
                    DetailEditSheet(field: field, store: store)
                } else {
                    BookingDetailsSheet(field: field, store: store)
                }
            }
            .environment(\.units, units)
        }
        .failureAlert(Binding(get: { store.trackingError }, set: { if $0 == nil { store.clearTrackingError() } }),
                      title: "Couldn't Stop Following", retry: { stopTracking() })
        // The Alerts switch went back (I4): its own alert, whose Try Again sends the switch again.
        .failureAlert(Binding(get: { store.notifyError }, set: { if $0 == nil { store.clearNotifyError() } }),
                      title: "Couldn't Change Alerts", retry: { Task { await store.retryNotify() } })
        .confirmDestructive(isPresented: $confirmingStop,
                            title: store.flight.map { String(localized: "Stop following \(Format.ident($0.ident))?",
                                                             bundle: .main) } ?? "",
                            message: DetailFacts.stopFollowingMessage,
                            actionTitle: "Stop Following") { stopTracking() }
        .alert(Text(ui: "Notifications Are Off"), isPresented: $askingSettings) {
            Button("Open Settings") { openNotificationSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ui: DetailFacts.alertsDeniedMessage)
        }
        // Read again when the app comes back: the user may have turned alerts on in Settings.
        .task(id: scenePhase) { await readAlertPermission() }
        .sensoryFeedback(.error, trigger: pasteFailures)
        .task(id: store.flight?.id) {
            if store.flight != nil { await store.loadExtras(now: fixedNow ?? .now) }
        }
        // Only a followed flight has a live link (the server checks the follow), so only it asks.
        .task(id: store.isFollowed ? store.flight?.id : nil) {
            guard let id = store.flight?.id, store.isFollowed else { return }
            if sharing == nil { sharing = FlightShareModel(flight: id, service: sharingService) }
            await sharing?.refresh()
        }
        .shareErrorAlert(sharing)
    }

    private func reload() { Task { await store.load() } }

    /// Sign In instead of Retry when the session is gone (E3); nil where the shell gives no sign-in sheet.
    private var signIn: (() -> Void)? {
        requestSignIn.map { action in { action() } }
    }

    /// True when the system drops this app's alerts. iOS only, and never for previews or tests (`now` fixed).
    private func readAlertPermission() async {
        #if os(iOS)
        guard fixedNow == nil, store.isFollowed else { return }
        alertsDenied = await SystemNotificationAuthorizer().status() == .denied
        #endif
    }

    private func openNotificationSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        #endif
    }

    /// False once the sheet is pulled down to its header, so the floating bar leaves.
    @State private var barShown = true

    /// Below this the sheet shows little more than its header: the bar would sit on the first card.
    static let barMinimumHeight: CGFloat = 300

    static func showsBar(height: CGFloat) -> Bool { height >= barMinimumHeight }

    /// Where the sheet opens: the top, or the bottom for screenshot runs (`-detailScroll bottom`).
    private static var startAnchor: UnitPoint? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "detailScroll") == "bottom" ? .bottom : nil
        #else
        nil
        #endif
    }

    /// Screenshot runs: `-detailScroll goodToKnow|forecast|plane|timetable|airline` opens the sheet with that card at
    /// the top, once the extras are in.
    private func jumpForScreenshots(_ proxy: ScrollViewProxy) async {
        #if DEBUG
        guard let target = UserDefaults.standard.string(forKey: "detailScroll"), target != "bottom" else { return }
        try? await Task.sleep(for: .milliseconds(400))
        proxy.scrollTo(target, anchor: .top)
        #endif
    }

    /// "Your 3rd flight on F-GSQA", nil when the tail is unknown or new to the traveller.
    private func tailLine(_ f: Flight) -> String? {
        guard let n = store.tailVisit, let reg = f.registration else { return nil }
        return TailVisitFacts.badge(n, registration: reg)
    }

    /// kg CO2e for one passenger in the seat class noted (economy when none), from the great circle distance
    /// between the airports; nil until both are known, and for a canceled or private flight.
    private func emissions(_ f: Flight) -> Double? {
        guard f.status != .canceled, let km = DetailFacts.distanceKm(origin: store.origin, destination: plannedDestination(f)),
              km > 0 else { return nil }
        return FlightEmissions.kilograms(km: km, seatClass: store.details?.seatClass, origin: store.origin?.country,
                                         destination: plannedDestination(f)?.country)
    }

    /// The sun, landmark and window side facts for the planned route, from the cache when the route, the
    /// aircraft, the seat and the clock are unchanged.
    private func routeFacts(_ f: Flight) -> RouteFacts {
        let type = f.aircraftType.flatMap { reference.type($0) }
        let destination = plannedDestination(f)
        let seat = store.details?.seat ?? store.boardingPass?.seat
        let key = RouteFactsCache.Key(flight: f.id, status: f.status, out: f.scheduledOut, in: f.scheduledIn,
                                      origin: store.origin?.id, destination: destination?.id,
                                      aircraft: f.aircraftType, seat: seat, clock: units.clock)
        return routeCache.facts(for: key) {
            guard let origin = store.origin, let destination else { return RouteFacts() }
            let events = SunFacts.events(f, origin: origin, destination: destination, aircraft: type)
            let passes = Landmarks.passes(f, origin: origin, destination: destination, aircraft: type)
            let window = WindowFacts.advice(f, origin: origin, destination: destination, aircraft: type)
                .map { WindowFacts.card($0, seat: seat, family: type?.family) }
            return RouteFacts(sun: SunFacts.lines(events, origin: origin, destination: destination, clock: units.clock),
                              landmarks: LandmarkFacts.lines(passes, origin: origin, destination: destination,
                                                             clock: units.clock),
                              window: window)
        }
    }

    private func airline(_ f: Flight) -> Airline? {
        f.operator.flatMap { reference.airline($0) } ?? reference.airline(ident: f.ident)
    }

    /// Live flights go stale after 5 minutes, the rest after an hour.
    static func ttl(_ f: Flight) -> Duration {
        f.status == .departed || f.status == .enRoute ? .seconds(300) : .seconds(3600)
    }

    private func sections(_ flight: Flight, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Lazy: the cards below the fold are built as they scroll in, not while the card rises.
            LazyVStack(alignment: .leading, spacing: 16) {
                // A failed refresh keeps the last known flight on screen under one inline card (R8).
                if let error = store.error {
                    RefreshErrorCard(error: error, updatedAt: flight.updatedAt, now: now, retry: reload, signIn: signIn)
                }
                if let error = store.detailsError {
                    ErrorBanner(error: error, signIn: signIn)
                }
                // The hero (R3): status, progress and the key facts in one card, coloured like the home row.
                DetailHeroCard(facts: heroFacts(flight, now: now), flight: flight, origin: store.origin,
                               aircraft: flight.aircraftType.flatMap { reference.type($0) },
                               pass: store.boardingPass, predictedGate: store.gatePrediction,
                               // "Updated 12 min. ago" once older than its TTL (E9); the error card says it otherwise.
                               freshness: store.isArchived || store.error != nil
                                   ? nil : (flight.updatedAt, Self.ttl(flight)),
                               now: now)
                    // Reloads a stale flight; drawn as a background so it adds no stack spacing.
                    .background {
                        if !store.isArchived {
                            SectionFreshness(fetchedAt: flight.updatedAt, ttl: Self.ttl(flight), now: now) {
                                await store.load()
                            }
                        }
                    }
                if !store.isArchived {
                    EstimatedProgressCard(flight: flight, origin: store.origin, destination: plannedDestination(flight), now: now)
                }
                // Canceled, or 3 hours late at the gate: the airline's line, its rebooking page, what to ask.
                if !store.isArchived, CancellationKit.isShown(flight) {
                    CancellationKitCard(flight: flight,
                                        contact: AirlineContacts.bundled.contact(airline(flight)?.id ?? flight.operator))
                }
                DepartArrive(flight: flight, origin: store.origin, destination: plannedDestination(flight), now: now,
                             onAirport: onAirport, predictedGate: store.gatePrediction,
                             lateTone: Self.lateTone(heroFacts(flight, now: now).level))
                    .scaledPadding(.top, 16)
                // An airport that did not load (E10): a quiet note, the flight itself is fine.
                if store.sectionErrors[.origin] != nil || store.sectionErrors[.destination] != nil {
                    SectionNote(text: DetailFacts.airportsNote)
                }
                if let details = store.details {
                    DetailTiles(details: details, onEdit: { if !store.isArchived { editing = $0 } },
                                onPaste: pasteAction, hint: pasteHint,
                                editing: $editing, store: store, empty: store.isArchived ? "Not noted" : "Tap to edit")
                        .scaledPadding(.top, 12)
                }
                // The boarding pass, kept on the device; on a followed flight without one, the row to add it.
                if store.boardingPass != nil || store.takesBoardingPass {
                    BoardingPassSection(store: store)
                        .id("boardingPass")
                }
                // About when the traveller's group is called, from the group on the pass.
                if !store.isArchived,
                   let group = BoardingGroupTiming.estimate(flight, pass: store.boardingPass,
                                                            aircraft: flight.aircraftType.flatMap { reference.type($0) },
                                                            originTimeZone: store.origin?.timeZone, now: now) {
                    BoardingGroupRow(estimate: group, timeZone: store.origin?.timeZone ?? .current)
                }
                // Connections with other followed flights; other flights when canceled or a connection is at risk.
                if let connections = store.connections, ConnectionSections.isShown(connections, flight: flight, now: now) {
                    ConnectionSections(store: connections, flight: flight, now: now)
                }
            }
            .scaledPadding(.horizontal, Theme.gutter)
            .scaledPadding(.top, 8)
            .scaledPadding(.bottom, 24)

            VStack(alignment: .leading, spacing: 16) {
                GoodToKnow(origin: .init(icao: flight.originIcao, code: flight.originCode, stats: store.originStats,
                                         weather: store.originWeather, departures: true),
                           destination: arrivalSide(flight),
                           timeZone: timeZoneChange(flight),
                           security: securityRow(flight, now: now),
                           leave: store.isArchived ? nil : flight, now: now,
                           predictedDelay: store.delayPrediction(now: now), predictedGate: store.gatePrediction,
                           advisories: FAAFacts.rows(store, flight: flight, clock: units.clock, now: now),
                           onAirport: onAirport)
                    .id("goodToKnow")
                FlightBriefSections(store: store, flight: flight, now: now)
                // Canceled or diverted: no arrival forecast and no inbound plane.
                let insights = FlightDetailStore.showsInsights(flight.status)
                if insights {
                    ForecastSection(forecast: store.forecast)
                        .id("forecast")
                }
                let type = flight.aircraftType.flatMap { reference.type($0) }
                if insights, PlaneSection.isShown(type: type, inbound: store.inbound) {
                    PlaneSection(flight: flight, type: type, airline: airline(flight), inbound: store.inbound,
                                 tailLine: tailLine(flight))
                        .id("plane")
                } else {
                    DetailCard {
                        CardTitle("Aircraft")
                            .scaledPadding(.bottom, 12)
                        AircraftRow(type: flight.aircraftType, registration: flight.registration,
                                    tailLine: tailLine(flight))
                    }
                }
                // Sunrises and sunsets seen from the plane, estimated from the schedule.
                let route = routeFacts(flight)
                let sun = route.sun
                if !sun.isEmpty {
                    SunInFlightCard(lines: sun)
                        .id("sun")
                }
                // Which window side to pick, and the landmarks the route passes, estimated from the schedule.
                if !store.isArchived, let window = route.window {
                    WindowSeatCard(card: window)
                        .id("window")
                }
                let landmarks = route.landmarks
                if !landmarks.isEmpty {
                    LandmarksCard(lines: landmarks)
                        .id("landmarks")
                }
                TimetableCard(rows: Timetable.rows(flight, originTz: store.origin?.timeZone ?? .gmt,
                                                   destinationTz: plannedDestination(flight)?.timeZone ?? .gmt,
                                                   clock: units.clock))
                    .id("timetable")
                AirlineCard(airline: airline(flight))
                    .id("airline")
                if !store.isArchived {
                    TravelDocumentsCard(airline: airline(flight), departure: flight.scheduledOut,
                                        international: ReminderPlanner.isInternational(
                                            origin: store.origin, destination: plannedDestination(flight)))
                    // International only: plugs, voltage, currency and tipping where the flight lands.
                    if let destination = plannedDestination(flight),
                       let facts = DestinationTable.bundled.card(origin: store.origin, destination: destination) {
                        DestinationCard(country: reference.country(facts.id)?.name ?? destination.city, facts: facts,
                                        showsESIM: !GlanceFacts.hasLeft(flight) && flight.status != .canceled)
                    }
                }
                if let history = store.routeHistory {
                    RouteHistoryCard(history: history, from: flight.originCode, to: flight.destinationCode)
                }
                UpdatesCard(events: store.events, timeZone: store.origin?.timeZone ?? .current)
                if store.sectionErrors[.events] != nil, store.events.isEmpty {
                    SectionNote(text: DetailFacts.updatesNote)
                }
                if flight.status == .diverted, let diverted = store.destination, diverted.id != flight.destinationIcao {
                    DetailCard {
                        AirportLinkRow(role: "Diverted to", code: diverted.id, airport: diverted, tag: "Diverted") {
                            onAirport(diverted.id)
                        }
                    }
                }
                // A Passport flight's photos, kept on the device.
                if let travelJournal, store.isArchived {
                    TravelJournalCard(journal: travelJournal, flight: flight.id)
                }
                if let details = store.details, !store.isArchived || details.notes != nil {
                    NotesCard(notes: details.notes) { if !store.isArchived { editing = .notes } }
                        .detailEditor(.notes, editing: $editing, store: store)
                }
                // The flight's CO2, last of the cards (owner's call, 2026-11-08).
                if let kg = emissions(flight) {
                    EmissionsCard(kilograms: kg, seatClass: store.details?.seatClass)
                        .id("emissions")
                }
                ReportLink(url: DetailFacts.reportURL(flight, origin: store.origin?.timeZone ?? .gmt))
                    .scaledPadding(.top, Theme.Space.lg)
                // Where the status comes from and how old it is (E9, D4); a Passport flight is the user's record.
                if !store.isArchived {
                    StaleBadge(fetchedAt: flight.updatedAt, ttl: Self.ttl(flight), now: fixedNow,
                               source: DetailFacts.dataSource)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            .scaledPadding(.horizontal, Theme.gutter)
        }
        // The last card ends above the glass action bar (R4); the Mac has the actions in its header.
        .modifier(ActionBarRoom(on: !Self.barInHeader))
        .connectionUpdates(store.connections, flight: flight, now: now)
    }

    /// The Mac's 360 pt panel has no room for a floating bar: its three buttons go in the header.
    static var barInHeader: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Alerts on or off; nil hides the bell (the flight is not followed or sends no more alerts). Off while
    /// the system drops this app's alerts (E5), whatever the server holds.
    private func notify(_ flight: Flight) -> Bool? {
        guard DetailFacts.takesAlerts(flight), !store.isArchived, let on = store.notify else { return nil }
        return alertsDenied ? false : on
    }

    /// The bell: turns alerts on or off, or, when the system drops them, offers Settings.
    private func toggleNotify(_ on: Bool) {
        if alertsDenied { askingSettings = true; return }
        Task { await store.setNotify(on) }
    }

    /// The Mac panel's share, bell and menu, as small circles in the header.
    private func bottomBar(_ flight: Flight) -> some View {
        DetailBottomBar(share: shareItem(flight), notify: notify(flight),
                        onNotify: toggleNotify, compact: true) {
            moreMenu(flight)
        }
    }

    /// The phone's glass action bar (R4): More (the menu), Alerts (followed flights that still send alerts)
    /// and Share.
    private func actionBar(_ flight: Flight) -> some View {
        let notify = notify(flight)
        let share = shareItem(flight)
        return GlassActionBarContainer(count: notify == nil ? 2 : 3) {
            Menu { moreMenu(flight) } label: { GlassActionLabel(title: "More", systemImage: "ellipsis.circle") }
                .menuIndicator(.hidden)
                // Share stays on top even when the menu opens upward from the bar.
                .menuOrder(.fixed)
                .accessibilityLabel("More")
            if let notify {
                Button { toggleNotify(!notify) } label: {
                    GlassActionLabel(title: "Alerts", systemImage: notify ? "bell.fill" : "bell.slash",
                                     tint: notify ? Theme.accent : nil)
                }
                .accessibilityLabel(notify ? "Turn Off Alerts" : "Turn On Alerts")
                .accessibilityValue(notify ? "On" : "Off")
                .accessibilityHint(alertsDenied ? "Notifications are off in Settings" : "")
            }
            ShareLink(item: share, preview: SharePreview(share.title)) {
                GlassActionLabel(title: "Share", systemImage: "square.and.arrow.up")
            }
            .accessibilityLabel("Share Flight")
        }
    }

    /// The rarer actions, behind More.
    @ViewBuilder private func moreMenu(_ flight: Flight) -> some View {
        let share = shareItem(flight)
        ShareLink(item: share, preview: SharePreview(share.title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        if let sharing, sharing.isSharing {
            Button("Stop Sharing", systemImage: "link.badge.minus") { Task { await sharing.stop() } }
        }
        Divider()
        if let a = airline(flight) {
            let links = AirlineCard.buttons(a)
            if !links.isEmpty {
                Menu {
                    ForEach(links, id: \.self) { link in
                        Button(DetailFacts.menuTitle(link.title)) { openURL(link.url) }
                    }
                } label: {
                    Label("Contact Airline", systemImage: "phone")
                }
            }
        }
        let places = [store.origin, plannedDestination(flight)].compactMap { $0 }
        if !places.isEmpty {
            Menu {
                ForEach(places, id: \.id) { airport in
                    if let url = DetailFacts.mapsURL(airport) {
                        Button("\(airport.iata ?? airport.id) · \(DetailFacts.shortName(airport.name))") { openURL(url) }
                    }
                }
            } label: {
                Label("Open In Maps", systemImage: "map")
            }
        }
        Divider()
        if store.details != nil, !store.isArchived {
            Button("Edit Flight Record", systemImage: "pencil") { editing = .bookingCode }
        }
        Button(DetailFacts.reportLabel, systemImage: "exclamationmark.bubble") {
            // No mail app: the address goes to the pasteboard, as under the report link.
            openURL(DetailFacts.reportURL(flight, origin: store.origin?.timeZone ?? .gmt)) { accepted in
                if !accepted { Pasteboard.copy(DetailFacts.supportAddress) }
            }
        }
        if store.isFollowed { FlightTextsMenuItem(model: flightTexts) }
        if store.isFollowed {
            // A reversible unfollow (D3): "Stop Following", with Undo, or a confirmation when Undo is not on offer.
            Button("Stop Following", systemImage: "bell.slash", role: .destructive) { stopFollowingTapped(flight) }
        }
    }

    /// What Share hands over: a followed flight's live link, and the flight in words for every flight.
    private func shareItem(_ flight: Flight) -> FlightShareItem {
        FlightSharing.item(flight, origin: store.origin, destination: plannedDestination(flight),
                           clock: units.clock, model: store.isFollowed ? sharing : nil)
    }

    /// Stop Following (I1): through the shell's Undo toast when it takes the flight (the sheet closes at once,
    /// booking code, seat and notes come back with Undo); otherwise after a confirmation, since the server
    /// then drops them for good.
    private func stopFollowingTapped(_ flight: Flight) {
        if let stopFollowing, stopFollowing(flight) {
            onClose?()
        } else {
            confirmingStop = true
        }
    }

    private func stopTracking() {
        Task {
            if await store.stopTracking(via: onStopTracking) { onClose?() }
        }
    }

    /// Keeps pasted text only when it reads as a booking code; anything else says so under the tiles
    /// for a few seconds.
    /// The booking tile's paste; none on a Passport flight, which is read only.
    private var pasteAction: ((String) -> Void)? {
        store.isArchived ? nil : { paste($0) }
    }

    private func paste(_ text: String) {
        guard var next = store.details else { return }
        guard let code = DetailFacts.pastedBookingCode(text) else {
            pasteFailures += 1
            let attempt = pasteFailures
            pasteHint = DetailFacts.pasteHint
            Task {
                try? await Task.sleep(for: .seconds(3))
                if pasteFailures == attempt { pasteHint = nil }
            }
            return
        }
        pasteHint = nil
        next.bookingCode = code
        Task { await store.saveDetails(next) }
    }

    /// The destination's Good to Know block: where the flight actually lands.
    private func arrivalSide(_ f: Flight) -> GoodToKnow.Side {
        let icao = store.destination?.id ?? f.destinationIcao
        let code = store.destination.map { $0.iata ?? $0.id } ?? f.destinationCode
        // The forecast at arrival only matters while the flight still has to land.
        let pending: Set<FlightStatus> = [.scheduled, .departed, .enRoute, .unknown]
        return .init(icao: icao, code: code, stats: store.destinationStats, weather: store.destinationWeather,
                     departures: false, arrival: pending.contains(f.status) ? DetailFacts.bestIn(f) : nil,
                     timeZone: store.destination?.timeZone ?? .current)
    }

    /// The security row's data while the flight is in its window (`SecurityWaitFacts.isInWindow`).
    private func securityRow(_ f: Flight, now: Date) -> SecurityRowData? {
        guard !store.isArchived, let wait = store.securityWait, SecurityWaitFacts.isInWindow(f, now: now) else { return nil }
        return SecurityRowData(wait: wait, terminal: f.terminalOrigin, timeZone: store.origin?.timeZone ?? .current)
    }

    private func timeZoneChange(_ f: Flight) -> (title: String, text: String)? {
        guard let o = store.origin, let d = plannedDestination(f), let arrival = DetailFacts.bestIn(f) else { return nil }
        return DetailFacts.timeZoneChange(origin: o, destination: d, arrival: arrival, clock: units.clock)
    }

    /// A late side's colour in Depart / Arrive: red when the flight is very late, else amber.
    static func lateTone(_ level: DelayLevel) -> Color {
        level == .veryLate ? Theme.veryLate : Theme.late
    }

    /// The hero card's words and colour (R3), from the same summary as the home row.
    private func heroFacts(_ f: Flight, now: Date) -> HeroFacts {
        HeroFacts.make(f, airline: airline(f), origin: store.origin, planned: plannedDestination(f),
                       actual: store.destination, prediction: store.delayPrediction(now: now),
                       unit: units.distance, clock: units.clock, now: now)
    }

    /// The card and timeline describe the planned trip; a diversion target only shows when it is
    /// the planned airport.
    private func plannedDestination(_ f: Flight) -> Airport? {
        store.destination?.id == f.destinationIcao ? store.destination : nil
    }
}

// MARK: - Pieces

/// Removes a followed flight with Undo (I1): the shell sets it to `HomeModel.unfollowWithUndo` and returns
/// true when it took the flight; false (or no action) makes the sheet confirm and unfollow at once.
public struct StopFollowingAction {
    let run: @MainActor (Flight) -> Bool

    public init(_ run: @escaping @MainActor (Flight) -> Bool) { self.run = run }

    @MainActor public func callAsFunction(_ flight: Flight) -> Bool { run(flight) }
}

public extension EnvironmentValues {
    /// Set by the shell; nil makes the flight sheet confirm before it unfollows.
    @Entry var stopFollowing: StopFollowingAction? = nil
}

public extension View {
    /// What the flight sheet's Stop Following does: return true once the flight is hidden with an Undo toast.
    func onStopFollowing(_ action: @escaping @MainActor (Flight) -> Bool) -> some View {
        environment(\.stopFollowing, StopFollowingAction(action))
    }
}

/// The flight sheet when the server no longer has the flight (I7): what happened and Close, no Retry.
struct FlightGoneState: View {
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            Spacer(minLength: 0)
            Image(systemName: "airplane.circle")
                .scaledFont(44, weight: .regular)
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            Text(ui: "This flight is no longer available")
                .themeFont(.sectionTitle)
                .foregroundStyle(Theme.primary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(ui: "The airline may have removed or renumbered it. Search for it again to follow the new one.")
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let onClose {
                Button(action: onClose) {
                    Text(ui: "Close")
                        .scaledFont(17, weight: .semibold)
                        .scaledPadding(.horizontal, Theme.Space.lg)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.accent)
                .scaledPadding(.top, Theme.Space.xs)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaledPadding(.horizontal, Theme.Space.xl)
    }
}

/// A quiet line where a section's data did not load (E10): never "Couldn't refresh", the flight is fine.
struct SectionNote: View {
    var text: String

    var body: some View {
        Label { Text(ui: text) } icon: { Image(systemName: "info.circle") }
            .scaledFont(13)
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pads the sheet's content to end above the glass action bar: `refinedActionBarInset()` on the phone, a
/// plain 24 pt on the Mac, whose actions sit in the header.
private struct ActionBarRoom: ViewModifier {
    var on: Bool

    func body(content: Content) -> some View {
        if on {
            content.refinedActionBarInset()
        } else {
            content.scaledPadding(.bottom, 24)
        }
    }
}

/// Departure and arrival terminal, gate and belt, "TBA" until known.
struct AircraftRow: View {
    var type: String?
    var registration: String?
    /// "Your 3rd flight on F-GSQA" when the traveller has flown this tail before.
    var tailLine: String? = nil
    @ScaledMetric(relativeTo: .body) private var icon = 40

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "airplane")
                .scaledFont(18, weight: .semibold)
                .foregroundStyle(Theme.primary)
                .frame(width: icon, height: icon)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(type.map(TravelFacts.aircraftName) ?? "Aircraft not assigned yet")
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(type == nil ? Theme.secondary : Theme.primary)
                let parts = [type, registration].compactMap { $0 }
                if !parts.isEmpty {
                    Text(parts.joined(separator: "  ·  "))
                        .scaledFont(14)
                        .foregroundStyle(Theme.secondary)
                }
                if let tailLine {
                    TailBadge(text: tailLine).scaledPadding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One airport with its role, tappable to open the airport sheet.
struct AirportLinkRow: View {
    var role: String
    var code: String
    var airport: Airport?
    var iata: String?
    var tag: String?
    var action: () -> Void
    @ScaledMetric(relativeTo: .body) private var badge = 40

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(airport?.iata ?? iata ?? code)
                    .scaledFont(15, weight: .bold)
                    .foregroundStyle(Theme.primary)
                    .frame(width: badge, height: badge)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: UIText.localized(role).uppercased()).scaledFont(12, weight: .medium).foregroundStyle(Theme.secondary)
                        if let tag {
                            Text(verbatim: UIText.localized(tag).uppercased())
                                .scaledFont(11, weight: .semibold)
                                .foregroundStyle(Theme.diverted)
                        }
                    }
                    Text(airport?.name ?? code)
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    if let airport {
                        Text("\(airport.city), \(AirportFacts.countryName(airport.country))")
                            .scaledFont(14)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                RowChevron()
            }
            .scaledPadding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the airport")
    }
}

/// One change seen on the flight, newest first.
struct EventRow: View {
    @Environment(\.units) private var units
    var event: FlightEvent
    var timeZone: TimeZone

    var body: some View {
        if let text = DetailFacts.eventText(event) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: DetailFacts.eventIcon(event.kind))
                    .scaledFont(14, weight: .medium)
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(ui: text).scaledFont(15).foregroundStyle(Theme.primary)
                Spacer(minLength: 8)
                Text(Format.clock(event.receivedAt, timeZone, units.clock))
                    .scaledFont(14)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
            }
            .scaledPadding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Every change the backend saw on the flight, newest first, along a thin line; never blurred.
/// Draws nothing until there is one. "Every event" means every event a person can read: live position
/// samples (`position`, `eventText` nil) are left out, and the count line counts the rows shown.
struct UpdatesCard: View {
    var events: [FlightEvent]
    var timeZone: TimeZone
    @Environment(\.units) private var units

    private var shown: [(event: FlightEvent, text: String)] {
        events.reversed().compactMap { e in DetailFacts.eventText(e).map { (e, $0) } }
    }

    var body: some View {
        let rows = shown
        if !rows.isEmpty {
            DetailCard {
                CardTitle("Updates", subtitle: DetailFacts.updatesLine(rows.count))
                    .scaledPadding(.bottom, 10)
                ForEach(Array(rows.enumerated()), id: \.element.event.id) { index, row in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Image(systemName: DetailFacts.eventIcon(row.event.kind))
                                .scaledFont(13, weight: .semibold)
                                .foregroundStyle(Theme.primary)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Theme.pill))
                            if index < rows.count - 1 {
                                Rectangle().fill(Theme.separator).frame(width: 2).frame(maxHeight: .infinity)
                            }
                        }
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ui: row.text).scaledFont(17, weight: .medium).foregroundStyle(Theme.primary)
                            Text("\(ScreenFormat.day(row.event.receivedAt, timeZone)), "
                                 + Format.clock(row.event.receivedAt, timeZone, units.clock))
                                .scaledFont(14)
                                .monospacedDigit()
                                .foregroundStyle(Theme.secondary)
                        }
                        .scaledPadding(.bottom, index < rows.count - 1 ? 14 : 0)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// "Report a Data Issue", centred under the last card; opens a mail to support about this flight. With no
/// mail app to take it, the address goes to the pasteboard and a line under the link says so.
struct ReportLink: View {
    var url: URL
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        VStack(spacing: 4) {
            Button {
                openURL(url) { accepted in
                    guard !accepted else { return }
                    Pasteboard.copy(DetailFacts.supportAddress)
                    copied = true
                }
            } label: {
                Label(DetailFacts.reportLabel, systemImage: "exclamationmark.bubble")
                    .scaledFont(18)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .scaledPadding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Writes to support about this flight")
            if copied {
                Text(ui: DetailFacts.reportCopied)
                    .scaledFont(14)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Wording

enum DetailFacts {
    static let reportLabel = "Report a Data Issue"
    /// Where the flight status comes from, named at the foot of the sheet (D4).
    static let dataSource = "FlightAware"
    /// Under "Stop following AF 84?" when no Undo is on offer.
    static let stopFollowingMessage = "Its booking code, seat and notes will be removed."
    /// The bell while the system drops this app's alerts (E5).
    static let alertsDeniedMessage = "Soma Flight can't alert you about this flight. Turn notifications on in Settings."
    /// An airport that did not load while the flight did (E10).
    static let airportsNote = "Some airport details couldn't load. They'll come back on the next refresh."
    /// The updates list that did not load (E10).
    static let updatesNote = "This flight's updates couldn't load. They'll come back on the next refresh."
    static let supportAddress = "support@somalabs.me"
    /// Shown when no mail app opened the report.
    static let reportCopied = "No mail app found. We copied support@somalabs.me for you."

    /// "3 updates for this flight".
    static func updatesLine(_ count: Int) -> String {
        "\(count) \(count == 1 ? "update" : "updates") for this flight"
    }

    /// A mail to support about this flight: "Soma Flight data issue: UA990 2026-10-30", with the day it
    /// leaves in the origin's zone.
    static func reportURL(_ f: Flight, origin: TimeZone = .gmt) -> URL {
        var subject = "Soma Flight data issue: \(f.ident)"
        if let out = f.scheduledOut ?? f.estimatedOut ?? f.actualOut {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = origin
            let c = cal.dateComponents([.year, .month, .day], from: out)
            subject += String(format: " %04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "mailto:\(supportAddress)?subject=\(encoded)")!
    }

    /// "Air France  ·  In the air" style caption under the title.
    /// Canceled and finished flights send no more alerts, so they show no switch.
    static func takesAlerts(_ f: Flight) -> Bool {
        ![.canceled, .landed, .arrived].contains(f.status)
    }

    static func caption(_ f: Flight) -> String {
        let status: String = switch f.status {
        case .scheduled, .unknown: "Scheduled"
        case .departed: "Left the gate"
        case .enRoute: "In the air"
        case .landed: "Landed"
        case .arrived: "At the gate"
        case .canceled: "Canceled"
        case .diverted: "Diverted"
        }
        let airline = f.operator.map { AirportFacts.airlineCode($0) } ?? TravelFacts.airlineCode(ident: f.ident)
        return "\(airline)  ·  \(f.originCode) to \(f.destinationCode)  ·  \(status)"
    }

    /// Time left or since, from the best known gate times.
    static func progressLine(_ f: Flight, now: Date) -> String? {
        switch f.status {
        case .canceled, .diverted, .unknown: return nil
        case .landed, .arrived:
            guard let at = f.actualIn ?? f.actualOn else { return nil }
            let since = now.timeIntervalSince(at)
            return since < 60 ? "Landed just now" : "Landed \(ScreenFormat.span(since)) ago"
        case .departed, .enRoute:
            guard let end = f.actualIn ?? f.estimatedIn ?? f.scheduledIn, end > now else { return nil }
            return "Arrives in \(ScreenFormat.span(end.timeIntervalSince(now), floor: "under a minute"))"
        case .scheduled:
            guard let out = f.actualOut ?? f.estimatedOut ?? f.scheduledOut, out > now else { return nil }
            return "Leaves the gate in \(ScreenFormat.span(out.timeIntervalSince(now), floor: "under a minute"))"
        }
    }

    static func eventText(_ e: FlightEvent) -> String? {
        switch e.kind {
        case .gateChange: e.payload["gate"].map { "Gate changed to \($0)" } ?? "Gate changed"
        case .delay: e.payload["minutes"].flatMap(Int.init).map { "Delayed by \(Format.minutes($0))" } ?? "Delayed"
        case .departure: "Left the gate"
        case .arrival: "Arrived at the gate"
        case .cancel: "Canceled"
        case .diversion: e.payload["destination"].map { "Diverted to \($0)" } ?? "Diverted"
        case .position, .update: nil
        }
    }

    static func eventIcon(_ k: FlightEventKind) -> String {
        switch k {
        case .gateChange: "door.left.hand.open"
        case .delay: "clock.badge.exclamationmark"
        case .departure: "airplane.departure"
        case .arrival: "airplane.arrival"
        case .cancel: "xmark.circle"
        case .diversion: "arrow.triangle.branch"
        case .position: "location"
        case .update: "info.circle"
        }
    }
}

#if DEBUG
// MARK: - Previews

/// Loads a detail store from the seed at the seed's own clock.
struct FlightDetailPreview: View {
    enum Mode { case enRoute, sparse, canceled, diverted, error, stale, failed, noted }
    var mode: Mode = .enRoute
    @State private var store: FlightDetailStore?

    var body: some View {
        Group {
            if let store {
                FlightDetailView(store: store, onAirport: { _ in },
                                 now: PreviewData.now.addingTimeInterval(mode == .stale ? 40 * 60 : 0))
            } else {
                ProgressView()
            }
        }
        .task { store = await Self.makeStore(mode) }
    }

    static func makeStore(_ mode: Mode) async -> FlightDetailStore {
        let flights = FakeFlightService(now: PreviewData.now)
        let airports = FakeAirportService(now: PreviewData.now)
        let flight: Flight = switch mode {
        case .sparse: PreviewData.sparse
        case .canceled: PreviewData.canceled
        case .diverted: PreviewData.diverted
        default: PreviewData.enRoute
        }
        let s = FlightDetailStore(id: flight.id, flights: flights, airports: airports, history: FakeHistoryService(),
                                  insights: FakeInsightsService(flights: flights), gates: FakeGateHistoryService())
        if mode == .failed { await flights.setNextError(.providerUnavailable) }
        await s.load()
        await s.loadExtras()
        if mode == .error {
            await airports.setNextError(.providerUnavailable)
            await s.load()
        }
        if mode == .noted {
            await s.saveDetails(FollowDetails(seatClass: .business, seat: "23A", reason: .personal, bookingCode: "K7PQ2X",
                                              notes: "Lounge on the upper level past security. Ask for the exit row on the way back."))
        }
        return s
    }
}

#Preview("En route, dark") { FlightDetailPreview().preferredColorScheme(.dark) }
#Preview("En route, light") { FlightDetailPreview().preferredColorScheme(.light) }
#Preview("Sparse") { FlightDetailPreview(mode: .sparse).preferredColorScheme(.dark) }
#Preview("Canceled") { FlightDetailPreview(mode: .canceled).preferredColorScheme(.dark) }
#Preview("Diverted") { FlightDetailPreview(mode: .diverted).preferredColorScheme(.dark) }
#Preview("Error, data kept") { FlightDetailPreview(mode: .error).preferredColorScheme(.dark) }
#Preview("Stale") { FlightDetailPreview(mode: .stale).preferredColorScheme(.dark) }
#Preview("Noted") { FlightDetailPreview(mode: .noted).preferredColorScheme(.dark) }
#Preview("Failed, nothing to show") { FlightDetailPreview(mode: .failed).preferredColorScheme(.light) }
#endif

/// The route-derived facts of the flight sheet.
struct RouteFacts {
    var sun: [SunFacts.Line] = []
    var landmarks: [LandmarkFacts.Line] = []
    var window: WindowFacts.Card?
}

/// Keeps the last `RouteFacts` and the inputs they came from. A plain class held in `@State`: reading and
/// refilling it during a render does not invalidate the view.
@MainActor final class RouteFactsCache {
    struct Key: Hashable {
        var flight: UUID
        var status: FlightStatus
        var out: Date?
        var `in`: Date?
        var origin: String?
        var destination: String?
        var aircraft: String?
        var seat: String?
        var clock: TimeStyle
    }

    private var key: Key?
    private var value = RouteFacts()
    private(set) var computations = 0

    func facts(for key: Key, make: () -> RouteFacts) -> RouteFacts {
        if key != self.key {
            value = make()
            self.key = key
            computations += 1
        }
        return value
    }
}
