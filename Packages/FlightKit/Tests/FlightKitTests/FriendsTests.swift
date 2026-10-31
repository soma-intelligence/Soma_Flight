import CoreImage
import Foundation
import SwiftUI
import Testing
@testable import FlightKit

/// Friends: the `friends` function's answers (the backend's contract files) and the database functions' rows
/// decoded, invitation links and codes, the store on the fakes (switches, rollback, requests, invitations), the
/// home (the tab, the globe in the friends colour, a friend's flight read only, an opened invitation link).
@MainActor @Suite struct FriendsTests {
    static let contract = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FlightKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FlightKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repository root
        .appending(path: "supabase/functions/friends/contract")

    private func contract(_ name: String) throws -> Data {
        try Data(contentsOf: Self.contract.appending(path: "\(name).json"))
    }

    nonisolated static let now = ISO8601DateFormatter().date(from: "2026-11-03T08:00:00Z")!

    // MARK: Decoding

    @Test func decodesTheFunctionsAnswers() throws {
        let invite = try SupabaseFriendsService.decodeInvite(try contract("invite"))
        #expect(invite.url.absoluteString == "https://somalabs.me/i/C0ntractExampleT0kenC0ntractExampleT0kenABC")
        #expect(invite.expiresAt == ISO8601DateFormatter().date(from: "2026-11-10T08:00:00Z"))
        let preview = try SupabaseFriendsService.decodePreview(try contract("preview"))
        #expect(preview == FriendInvitePreview(state: .open, displayName: "Ada", emoji: "🌿"))
        #expect(try SupabaseFriendsService.decodeAccepted(try contract("accepted"))
                == UUID(uuidString: "0b0b0b0b-0000-4000-8000-00000000000b"))
        #expect(try SupabaseFriendsService.decodeRequested(try contract("requested")) == .sent)
        #expect(try SupabaseFriendsService.decodeCode(try contract("code")) == "K7M2X9QP")
    }

    @Test func refusesAnInviteThatIsNotHTTPS() {
        let data = Data(#"{"id":"1c1c1c1c-0000-4000-8000-00000000001c","url":"http://somalabs.me/i/x","expires_at":"2026-11-10T08:00:00Z"}"#.utf8)
        #expect(throws: DecodingError.self) { try SupabaseFriendsService.decodeInvite(data) }
    }

    @Test func decodesTheListAndFlightRows() throws {
        let list = Data("""
        [{"friend_id":"0b0b0b0b-0000-4000-8000-00000000000b","display_name":"Ada","emoji":null,
          "since":"2026-10-30T12:00:00+00:00","share_flights":true,"share_passport":false,"alerts":true,
          "shares_flights":true,"shares_passport":false}]
        """.utf8)
        let friends = try SupabaseFriendsService.decodeFriends(list)
        #expect(friends.count == 1)
        #expect(friends[0].settings == FriendSettings(shareFlights: true, sharePassport: false, alerts: true))
        #expect(friends[0].initials == "A")

        let rows = Data("""
        [{"friend_id":"0b0b0b0b-0000-4000-8000-00000000000b","id":"f2000000-0000-4000-8000-000000000001",
          "provider_id":"AFR84-1","ident":"AFR84","operator":"AFR","origin_icao":"LFPG","origin_iata":"CDG",
          "destination_icao":"KSFO","destination_iata":"SFO","scheduled_out":"2026-11-03T09:35:00+00:00",
          "scheduled_in":"2026-11-03T20:55:00+00:00","status":"en_route","gate_origin":"K41","baggage_belt":null,
          "position_lat":60.1,"position_lon":-30.2,"position_heading":280,"position_at":"2026-11-03T13:00:00+00:00",
          "updated_at":"2026-11-03T13:00:00+00:00"}]
        """.utf8)
        let flights = try SupabaseFriendsService.decodeFlights(rows)
        #expect(flights.count == 1)
        #expect(flights[0].friendId == friends[0].id)
        #expect(flights[0].flight.ident == "AFR84")
        #expect(flights[0].flight.gateOrigin == "K41")
        #expect(flights[0].flight.position != nil)
        #expect(try SupabaseFriendsService.decodePassport(Data("[]".utf8)) == nil)
    }

    @Test func functionBodiesNameTheAction() throws {
        let body = SupabaseFriendsService.body("request", ["code": "K7M2X9QP"])
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["action": "request", "code": "K7M2X9QP"])
    }

    // MARK: Links and codes

    @Test func readsInvitationLinks() {
        let token = "C0ntractExampleT0kenC0ntractExampleT0kenABC"
        #expect(FriendLink.token(from: URL(string: "https://somalabs.me/i/\(token)")!) == token)
        #expect(FriendLink.token(from: URL(string: "somaflight://i/\(token)")!) == token)
        #expect(FriendLink.token(from: URL(string: "https://evil.example/i/\(token)")!) == nil)
        #expect(FriendLink.token(from: URL(string: "https://somalabs.me/f/\(token)")!) == nil)
        #expect(FriendLink.token(from: URL(string: "somaflight://i/short")!) == nil)
        #expect(FriendLink.token(from: URL(string: "somaflight://flight/\(UUID().uuidString)")!) == nil)
    }

    @Test func readsFriendCodes() {
        #expect(FriendLink.code(" k7m2-x9qp ") == "K7M2X9QP")
        #expect(FriendLink.code("K7M2X9Q") == nil)
        #expect(FriendLink.code("K7M2X9QU") == nil, "U is not in Crockford's alphabet")
        #expect(FriendsMe(friendCode: "K7M2X9QP").spacedCode == "K7M2 X9QP")
    }

    @Test func profileFieldsAreCleaned() {
        #expect(FriendsStore.clean("  Maya  ", max: 40) == "Maya")
        #expect(FriendsStore.clean("   ", max: 40) == nil)
        #expect(FriendsStore.clean(String(repeating: "x", count: 50), max: 40)?.count == 40)
        #expect(FriendsStore.cleanEmoji("🌿🌊") == "🌿")
        #expect(FriendsStore.cleanEmoji("ab") == nil)
        #expect(FriendAvatarText.initials("Theo Martin Smith") == "TM")
        #expect(FriendAvatarText.initials(nil) == "?")
    }

    // MARK: Store

    private func loaded(_ service: FakeFriendsService = FakeFriendsService(now: now)) async -> FriendsStore {
        let store = FriendsStore(service: service)
        await store.load()
        return store
    }

    @Test func loadsTwoFriendsTheirFlightsAndARequest() async {
        let store = await loaded()
        #expect(store.friends.map(\.name) == ["Maya", "Theo Martin"])
        #expect(store.flights.count == 2)
        #expect(store.incoming.count == 1)
        #expect(store.me?.friendCode == "K7M2X9QP")
        #expect(store.nextFlight(of: FakeFriendsService.maya) != nil)
        // Friends' flights never carry the user's own ids.
        let own = FakeSeed.flights("followed", shift: FakeSeed.shift(now: Self.now)).map(\.id)
        #expect(store.flights.allSatisfy { !own.contains($0.flight.id) })
    }

    @Test func flyingSoonKeepsFriendsInTheAirOrLeavingWithinADay() async {
        let store = await loaded()
        store.filter = .soon
        let air = store.flights.first { $0.friendId == FakeFriendsService.maya }!.flight
        #expect(FriendsStore.isSoon(air, now: Self.now))
        var later = air
        later.status = .scheduled; later.scheduledOut = Self.now.addingTimeInterval(3 * 86_400)
        later.estimatedOut = nil; later.actualOut = nil
        #expect(!FriendsStore.isSoon(later, now: Self.now))
        #expect(store.visibleFriends(now: Self.now).contains { $0.id == FakeFriendsService.maya })
    }

    @Test func aSwitchShowsAtOnceAndGoesBackOnFailure() async {
        let service = FakeFriendsService(now: Self.now)
        let store = await loaded(service)
        let theo = FakeFriendsService.theo
        await store.update(theo) { $0.alerts = true }
        #expect(store.friend(theo)?.settings.alerts == true)
        #expect(await service.friendList.first { $0.id == theo }?.settings.alerts == true)
        await service.setNextError(.offline)
        await store.update(theo) { $0.sharePassport = true }
        #expect(store.friend(theo)?.settings.sharePassport == false)
        #expect(store.error == .offline)
    }

    @Test func pausingAndRemoving() async {
        let store = await loaded()
        await store.setPaused(true)
        #expect(store.me?.sharingPaused == true)
        await store.remove(FakeFriendsService.theo)
        #expect(store.friend(FakeFriendsService.theo) == nil)
        #expect(store.flights(of: FakeFriendsService.theo).isEmpty)
    }

    @Test func passportTotalsOnlyWhenShared() async {
        let store = await loaded()
        await store.loadPassport(of: FakeFriendsService.maya)
        await store.loadPassport(of: FakeFriendsService.theo)
        #expect(store.passports[FakeFriendsService.maya]?.flights == 64)
        #expect(store.passports[FakeFriendsService.theo] == nil)
    }

    @Test func requestsAndCodes() async throws {
        let store = await loaded()
        let sam = try #require(store.incoming.first)
        await store.respond(to: sam, accept: true)
        #expect(store.friends.contains { $0.displayName == "Sam" })
        #expect(store.incoming.isEmpty)
        #expect(try await store.request(code: "r4tw-8h2c") == .sent)
        #expect(store.outgoing.count == 1)
        await #expect(throws: APIError.notFound) { try await store.request(code: "nope") }
        await store.cancel(store.outgoing[0])
        #expect(store.outgoing.isEmpty)
        await store.resetCode()
        #expect(store.me?.friendCode == "R4TW8H2C")
        #expect(await store.makeInvite()?.url.absoluteString.hasPrefix("https://somalabs.me/i/") == true)
    }

    @Test func profileSaves() async {
        let store = await loaded()
        #expect(await store.saveProfile(displayName: "  Q  ", emoji: "🛫x"))
        #expect(store.me?.displayName == "Q")
        #expect(store.me?.emoji == "🛫")
    }

    // MARK: Words

    @Test func rowStatusSaysWhereTheFlightIs() {
        var f = PreviewData.enRoute
        f.status = .enRoute
        #expect(FriendFacts.status(f, now: PreviewData.now).text.hasPrefix("In the air"))
        f.status = .canceled
        #expect(FriendFacts.status(f, now: PreviewData.now).text == "Canceled")
        var s = PreviewData.enRoute
        s.status = .scheduled
        s.scheduledOut = PreviewData.now.addingTimeInterval(5 * 3600)
        s.estimatedOut = s.scheduledOut!.addingTimeInterval(25 * 60)
        s.actualOut = nil; s.actualOff = nil
        #expect(FriendFacts.status(s, now: PreviewData.now).text == "Leaves in 5 h · 25 min late")
        s.estimatedOut = s.scheduledOut!.addingTimeInterval(90 * 60)
        #expect(FriendFacts.lateText(s) == "1 h 30 min late")
    }

    // MARK: Tab redesign

    @Test func theListFallsIntoInTheAirUpcomingAndNothing() async {
        let store = await loaded()
        let groups = store.sections()
        #expect(groups.map(\.section) == [.inTheAir, .upcoming])
        #expect(groups[0].friends.map(\.id) == [FakeFriendsService.maya])
        #expect(groups[1].friends.map(\.id) == [FakeFriendsService.theo])
        #expect(FriendsStore.Section.allCases.map(\.title) == ["In the Air", "Upcoming", "No Upcoming Flights"])
    }

    @Test func sectionsSortByTimeThenNameAndDropLandedFlights() async {
        let store = FriendsStore(service: FakeFriendsService(now: Self.now))
        func friend(_ n: Int, _ name: String) -> Friend {
            Friend(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000\(n)")!, displayName: name, since: Self.now)
        }
        let ana = friend(1, "Ana"), ben = friend(2, "ben"), cleo = friend(3, "Cleo"), dan = friend(4, "Dan"), eve = friend(5, "Eve")
        func flight(_ n: Int, _ status: FlightStatus, out hours: Double) -> Flight {
            var f = PreviewData.enRoute
            f.id = UUID(uuidString: "00000000-0000-4000-8000-0000000000F\(n)")!
            f.status = status
            f.scheduledOut = Self.now.addingTimeInterval(hours * 3600)
            f.estimatedOut = nil; f.actualOut = nil
            f.scheduledIn = f.scheduledOut!.addingTimeInterval(5 * 3600)
            f.estimatedIn = nil; f.actualIn = nil
            return f
        }
        store.seed(friends: [eve, dan, cleo, ben, ana], flights: [
            FriendFlight(friendId: ana.id, flight: flight(1, .scheduled, out: 10)),
            FriendFlight(friendId: ben.id, flight: flight(2, .scheduled, out: 2)),
            FriendFlight(friendId: cleo.id, flight: flight(3, .landed, out: -8)),
            FriendFlight(friendId: dan.id, flight: flight(4, .canceled, out: 4)),
        ])
        let groups = store.sections()
        #expect(groups.map(\.section) == [.upcoming, .noFlights])
        // A canceled flight stays news; a landed one is not upcoming.
        #expect(groups[0].friends.map(\.name) == ["ben", "Dan", "Ana"])
        #expect(groups[1].friends.map(\.name) == ["Cleo", "Eve"])
        #expect(store.upcomingFlight(of: cleo.id) == nil)
        #expect(store.nextFlight(of: cleo.id) != nil, "the friend page keeps every shared flight")
    }

    @Test func rowLineSaysRouteAndWhen() {
        var f = PreviewData.enRoute
        f.ident = "AF84"
        let route = FriendFacts.route(f, lookup: { _ in nil })
        #expect(route.hasPrefix("AF 84 · "))
        #expect(route.contains(" → "))
        let paris = Airport(id: f.originIcao, name: "Charles de Gaulle", city: "Paris", country: "FR", lat: 0, lon: 0, tz: "Europe/Paris")
        #expect(FriendFacts.route(f, lookup: { $0 == f.originIcao ? paris : nil }) == "AF 84 · Paris → \(f.destinationCode)")

        f.status = .scheduled
        f.scheduledOut = PreviewData.now.addingTimeInterval(3 * 3600); f.estimatedOut = nil; f.actualOut = nil
        #expect(FriendFacts.when(f, now: PreviewData.now).text == "departs in 3h")
        f.estimatedOut = f.scheduledOut!.addingTimeInterval(25 * 60)
        #expect(FriendFacts.when(f, now: PreviewData.now).text == "departs in 3h · 25 min late")
        f.status = .enRoute
        f.actualIn = nil; f.estimatedIn = PreviewData.now.addingTimeInterval(80 * 60)
        #expect(FriendFacts.when(f, now: PreviewData.now).text == "in the air · lands in 1h 20m")
        f.status = .canceled
        #expect(FriendFacts.when(f, now: PreviewData.now).text == "canceled")
    }

    @Test func spansStayShort() {
        #expect(FriendFacts.span(-5) == "0 min")
        #expect(FriendFacts.span(40) == "40 min")
        #expect(FriendFacts.span(100) == "1h 40m")
        #expect(FriendFacts.span(120) == "2h")
        #expect(FriendFacts.span(200) == "3h")
        #expect(FriendFacts.span(1440) == "1 day")
        #expect(FriendFacts.span(4 * 1440 + 30) == "4 days")
    }

    @Test func theCodeReadsAndTravelsWell() {
        #expect(FriendFacts.spokenCode("K7M2X9QP") == "K 7 M 2, X 9 Q P")
        #expect(FriendFacts.codePlaceholder.count == FriendsMe(friendCode: "K7M2X9QP").spacedCode.count)
        #expect(FriendFacts.inviteMessage(code: "K7M2X9QP").hasSuffix("My friend code is K7M2 X9QP."))
        #expect(!FriendFacts.inviteMessage(code: nil).contains("code"))
    }

    @Test func avatarTonesAreStable() {
        let id = UUID(uuidString: "F7E4D000-0000-4000-8000-00000000A0A1")!
        let tone = FriendAvatarText.tone(id, count: 6)
        #expect((0..<6).contains(tone))
        #expect(FriendAvatarText.tone(id, count: 6) == tone)
        #expect(FriendAvatarText.tone(nil, count: 6) == 0)
        let spread = Set((1...40).map { FriendAvatarText.tone(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0))!, count: 6) })
        #expect(spread.count > 3)
    }

    @Test func oneShareMakesOneInvitation() async throws {
        let store = await loaded()
        async let a = store.shareInviteURL()
        async let b = store.shareInviteURL()
        let (first, second) = try await (a, b)
        #expect(first == second)
        let third = try await store.shareInviteURL()
        #expect(third != first, "each share after that gets its own single-use link")
        #expect(third.absoluteString.hasPrefix("https://somalabs.me/i/"))
    }

    @Test func aFailedInvitationThrowsItsError() async {
        let service = FakeFriendsService(now: Self.now)
        let store = await loaded(service)
        await service.setNextError(.offline)
        await #expect(throws: APIError.offline) { try await store.shareInviteURL() }
    }

    #if canImport(AppKit)
    @Test func theQRCodeOpensTheInvitation() throws {
        let link = "https://somalabs.me/i/C0ntractExampleT0kenC0ntractExampleT0kenABC"
        let image = try #require(FriendQR.image(link, scale: 8))
        #expect(image.width == image.height && image.width % 8 == 0)
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        let found = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(found == [link])
    }
    #endif

    // MARK: Home

    private func home() async throws -> HomeModel {
        let home = HomeModel(env: try await AppEnvironment.fake(now: Self.now))
        await home.load()
        return home
    }

    @Test func friendsTabSitsBetweenMyFlightsAndPassport() {
        #expect(HomeTab.allCases == [.flights, .friends, .passport])
    }

    @Test func theGlobeDrawsFriendsInTheirOwnStyleOnTheFriendsTab() async throws {
        let home = try await home()
        #expect(home.globe.routes.allSatisfy { !$0.isFriend })
        home.tab = .friends
        let g = home.globe
        #expect(!g.routes.isEmpty)
        #expect(g.routes.allSatisfy { $0.isFriend })
        #expect(g.planes.allSatisfy { $0.isFriend })
        #expect(GlobeMap.strokeStyle(g.routes[0]).dash == [6, 5])
        #expect(GlobeMap.stroke(g.routes[0]) == Theme.friend)
    }

    @Test func aFriendsPlaneOpensTheirFlightReadOnlyOverTheirPage() async throws {
        let home = try await home()
        home.tab = .friends
        let ff = try #require(home.friends.flights.first)
        home.open(friend: ff.friendId)
        #expect(home.shell.path == [.friend(ff.friendId)])
        home.select(.flight(ff.flight.id))
        #expect(home.shell.path == [.friend(ff.friendId), .friendFlight(ff)])
        #expect(home.focus != nil)

        let store = FlightDetailStore(friend: ff.flight, flights: home.env.flights, airports: home.env.airports)
        await store.load()
        #expect(store.isArchived)
        #expect(!store.isFollowed)
        #expect(store.details == nil)
        #expect(store.boardingPass == nil)
    }

    @Test func anOpenedInvitationAsksThenMakesAFriend() async throws {
        let home = try await home()
        let url = URL(string: "somaflight://i/\(FakeFriendsService.junToken)")!
        #expect(await home.handleInvite(url: url))
        #expect(home.tab == .friends)
        #expect(home.pendingInvite?.preview?.state == .open)
        #expect(await home.answerInvite(accept: true) == nil)
        #expect(home.pendingInvite == nil)
        #expect(home.friends.friends.contains { $0.displayName == "Jun" })
        #expect(await home.handleInvite(url: URL(string: "https://example.com")!) == false)
    }
}
