import Foundation
import Testing
@testable import FlightKit

/// The boarding pass from the flight sheet and from a file opened in the app, over the fakes.
@Suite @MainActor struct BoardingPassFlowTests {
    /// A scanned pass for `f`, its day taken at the origin.
    static func pass(for f: Flight, seat: String? = "14C", code: String? = "QW3RT9") -> BoardingPass {
        let tz = PreviewData.airport(f.originIcao)?.timeZone ?? .gmt
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let designator = TravelFacts.airlineCode(ident: f.ident)
        return BoardingPass(source: .scan, passenger: "Ana Silva", carrier: designator,
                            flightNumber: String(f.ident.dropFirst(designator.count)), origin: f.originIata ?? f.originIcao,
                            destination: f.destinationIata ?? f.destinationIcao,
                            departureDay: f.scheduledOut.map { cal.dateComponents([.year, .month, .day], from: $0) },
                            seat: seat, compartment: "Y", bookingReference: code)
    }

    static var otherFollowed: Flight { PreviewData.followed.first { $0.ident != "AF84" && $0.status == .scheduled }! }

    static var notFollowed: Flight {
        let followed = Set(PreviewData.followed.map(\.id))
        return PreviewData.boards.flatMap(\.flights).first { !followed.contains($0.id) && $0.scheduledOut != nil }!
    }

    private func store(_ id: Flight.ID, shelf: BoardingPassShelf = .inMemory()) async -> FlightDetailStore {
        let s = FlightDetailStore(id: id, flights: FakeFlightService(now: PreviewData.now),
                                  airports: FakeAirportService(now: PreviewData.now), passes: shelf.vault(for: nil),
                                  lookup: { PreviewData.airport($0) })
        await s.load()
        return s
    }

    // MARK: Fakes

    @Test func fakePassIsAValidBCBPForAF84() throws {
        let fake = FakeBoardingPass.af84(now: PreviewData.now)
        let message = try #require(fake.barcode?.message)
        let bcbp = try BCBP.parse(message)
        let leg = try #require(bcbp.legs.first)
        #expect(leg.carrier == "AF" && leg.flightNumber == "84" && leg.from == "CDG" && leg.to == "SFO")
        #expect(leg.seat == "6A" && leg.pnr == "K7PQ2X")
        let scanned = BoardingPass(bcbp: bcbp, barcode: fake.barcode, near: PreviewData.now,
                                   timeZone: PreviewData.airport("LFPG")!.timeZone)
        #expect(scanned.departureDay == fake.departureDay)
        #expect(BoardingPassMatch.matches(fake, PreviewData.enRoute, lookup: { PreviewData.airport($0) }))
        #expect(BoardingPassMatch.matches(scanned, PreviewData.enRoute, lookup: { PreviewData.airport($0) }))
    }

    @Test func fakeEnvironmentShowsThePassOnAF84() async throws {
        let env = try await AppEnvironment.fake()
        #expect(env.simulatesWallet)
        let s = env.makeFlightDetailStore(id: FakeBoardingPass.flightId, owner: nil)
        await s.load()
        #expect(s.boardingPass?.ident == "AF84")
        #expect(s.simulatesWallet)
        // The shifted seed and the shifted pass still agree on the day.
        let f = try #require(s.flight)
        #expect(BoardingPassMatch.matches(try #require(s.boardingPass), f, lookup: env.lookup))
    }

    // MARK: Flight sheet

    @Test func attachKeepsThePassAndFillsEmptyDetails() async {
        let f = Self.otherFollowed
        let s = await store(f.id)
        #expect(s.boardingPass == nil)
        #expect(s.takesBoardingPass)
        let result = await s.attach(Self.pass(for: f), walletFile: nil)
        #expect(result == .attached)
        #expect(s.boardingPass?.flightId == f.id)
        #expect(s.details?.seat == "14C")
        #expect(s.details?.bookingCode == "QW3RT9")
        #expect(s.details?.seatClass == .economy)
    }

    @Test func attachLeavesSetDetailsAlone() async {
        let f = Self.otherFollowed
        let s = await store(f.id)
        await s.saveDetails(FollowDetails(seatClass: .business, seat: "2A", bookingCode: "MINE01"))
        _ = await s.attach(Self.pass(for: f), walletFile: nil)
        #expect(s.details == FollowDetails(seatClass: .business, seat: "2A", bookingCode: "MINE01"))
    }

    @Test func attachRefusesAnotherFlightsPass() async {
        let s = await store(Self.otherFollowed.id)
        let result = await s.attach(Self.pass(for: PreviewData.enRoute), walletFile: nil)
        guard case .otherFlight(let summary) = result else {
            Issue.record("expected otherFlight, got \(result)")
            return
        }
        #expect(summary.hasPrefix("AF 84 · CDG to SFO"))
        #expect(s.boardingPass == nil)
    }

    @Test func passOutlivesTheStoreAndRemoves() async {
        let f = Self.otherFollowed
        let shelf = BoardingPassShelf.inMemory()
        let first = await store(f.id, shelf: shelf)
        _ = await first.attach(Self.pass(for: f), walletFile: Data("file".utf8))
        let second = await store(f.id, shelf: shelf)
        #expect(second.boardingPass?.passenger == "Ana Silva")
        #expect(await second.walletFile() == Data("file".utf8))
        await second.removeBoardingPass()
        #expect(second.boardingPass == nil)
        #expect(await store(f.id, shelf: shelf).boardingPass == nil)
    }

    @Test func passportFlightTakesNoPass() async throws {
        let past = try #require(FakeSeed.load("past_flights", as: [PastFlight].self).first)
        let s = FlightDetailStore(past: past, flights: FakeFlightService(), airports: FakeAirportService())
        #expect(!s.takesBoardingPass)
        #expect(await s.attach(Self.pass(for: past.asFlight), walletFile: nil) == .failed)
    }

    // MARK: Opened from outside

    private func home() async throws -> HomeModel {
        let home = HomeModel(env: try await AppEnvironment.fake(now: PreviewData.now))
        await home.load()
        return home
    }

    @Test func followedFlightTakesThePassAndOpens() async throws {
        let home = try await home()
        let f = Self.otherFollowed
        await home.importPass(Self.pass(for: f), walletFile: nil)
        #expect(home.passImport == nil)
        #expect(home.shell.path == [.flight(f.id)])
        #expect(home.toast?.hasPrefix("Boarding pass added to") == true)
        #expect(await home.env.passes.vault(for: home.owner).pass(for: f.id) != nil)
        #expect(try await home.env.flights.followDetails(f.id)?.seat == "14C")
    }

    @Test func unfollowedFlightIsOfferedThenFollowed() async throws {
        let home = try await home()
        let f = Self.notFollowed
        await home.importPass(Self.pass(for: f), walletFile: Data("w".utf8))
        #expect(home.passImport?.state == .follow(f))
        await home.followAndKeepPass()
        #expect(home.passImport == nil)
        #expect(home.followed.contains { $0.id == f.id })
        let vault = home.env.passes.vault(for: home.owner)
        #expect(await vault.pass(for: f.id)?.flightId == f.id)
        #expect(await vault.walletFile(for: f.id) == Data("w".utf8))
        #expect(home.shell.path == [.flight(f.id)])
    }

    @Test func unknownFlightSaysSo() async throws {
        let home = try await home()
        var pass = Self.pass(for: Self.notFollowed)
        pass.flightNumber = "9999"
        await home.importPass(pass, walletFile: nil)
        #expect(home.passImport?.state == .notFound)
    }

    @Test func unreadableFileSaysSo() async throws {
        let home = try await home()
        let url = FileManager.default.temporaryDirectory.appending(path: "bad-\(UUID().uuidString).pkpass")
        try Data("not a pass".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await home.importPass(from: url)
        #expect(home.passImport?.state == .unreadable)
    }

    @Test func passFileIsReadFromDisk() async throws {
        let json = try PassFixture.json(PassFixture.airFrance())
        let url = FileManager.default.temporaryDirectory.appending(path: "af-\(UUID().uuidString).pkpass")
        let data = try PassFixture.pkpass(["pass.json": json])
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try await PassFile.read(url)
        #expect(read.pass.ident == "AF84")
        #expect(read.walletFile == data)
        #expect(PassFile.isPassFile(url))
        #expect(!PassFile.isPassFile(URL(string: "somaflight://auth")!))
    }

    // MARK: Wording

    @Test func ticketAndGridFacts() {
        var pass = FakeBoardingPass.af84(now: PreviewData.now)
        let paris = PreviewData.airport("LFPG")
        let ticket = BoardingPassFacts.ticketFacts(pass, flight: PreviewData.enRoute, origin: paris, clock: .h24)
        #expect(ticket.map(\.label) == ["Seat", "Zone", "Boarding"])
        #expect(ticket.last?.value == "12:20")
        var moved = PreviewData.enRoute
        moved.gateOrigin = "K30"
        let grid = PassCardFacts.grid(pass, flight: moved, origin: paris, clock: .h24)
        #expect(grid.first == PassCardFacts.Item(label: "Gate", value: "K30", note: "Was B22"))
        #expect(grid.map(\.label).contains("Class"))
        pass.group = "3"
        #expect(BoardingPassFacts.groupFact(pass) == .init(label: "Group · Zone", value: "3 · 1"))
        #expect(PassCardFacts.barcodeCaption(pass) == "K7PQ2X  ·  SEQ 41")
    }
}
