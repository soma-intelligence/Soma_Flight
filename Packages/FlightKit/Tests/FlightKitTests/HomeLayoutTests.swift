import SwiftUI
import Testing
@testable import FlightKit

/// Which home layout each window shape gets, on the Duo's screens, other iPhones and the iPad.
@Suite struct HomeLayoutTests {
    @Test func duoInnerScreen() {
        #expect(HomeLayout.resolve(isPad: false, regularWidth: true, size: .init(width: 626, height: 890)) == .duoUpright)
        #expect(HomeLayout.resolve(isPad: false, regularWidth: true, size: .init(width: 890, height: 626)) == .duoSideways)
    }

    @Test func phonesKeepTheSheet() {
        #expect(HomeLayout.resolve(isPad: false, regularWidth: false, size: .init(width: 466, height: 678)) == .sheet) // Duo cover
        #expect(HomeLayout.resolve(isPad: false, regularWidth: false, size: .init(width: 402, height: 874)) == .sheet) // 17 Pro
        #expect(HomeLayout.resolve(isPad: false, regularWidth: false, size: .init(width: 874, height: 402)) == .sheet)
        #expect(HomeLayout.resolve(isPad: false, regularWidth: true, size: .init(width: 956, height: 440)) == .sheet) // Pro Max sideways
    }

    @Test func iPadIsUnchanged() {
        #expect(HomeLayout.resolve(isPad: true, regularWidth: true, size: .init(width: 1376, height: 1032)) == .panels)
        #expect(HomeLayout.resolve(isPad: true, regularWidth: false, size: .init(width: 320, height: 1032)) == .sheet)
    }

    @Test func sixHundredIsADuo() {
        #expect(HomeLayout.resolve(isPad: false, regularWidth: false, size: .init(width: 600, height: 800)) == .duoUpright)
        #expect(HomeLayout.resolve(isPad: false, regularWidth: false, size: .init(width: 599, height: 800)) == .sheet)
    }

    @Test func squareIsUpright() {
        #expect(HomeLayout.resolve(isPad: false, regularWidth: true, size: .init(width: 700, height: 700)) == .duoUpright)
    }

    @Test func isDuo() {
        #expect(HomeLayout.duoUpright.isDuo && HomeLayout.duoSideways.isDuo)
        #expect(!HomeLayout.sheet.isDuo && !HomeLayout.panels.isDuo)
    }
}
