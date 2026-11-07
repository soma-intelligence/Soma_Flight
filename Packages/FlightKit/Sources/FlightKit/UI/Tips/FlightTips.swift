import SwiftUI
import TipKit

/// The few one-time hints the app shows (TipKit). Each shows once, and closing it or using what it points
/// at puts it away for good. The app turns them on at launch (`FlightTips.configure()`); without that call,
/// as in previews, snapshot tests and screenshot runs, none shows.
public enum FlightTips {
    /// Turns the tips on. Screenshot runs (`-useFakes`) keep them hidden.
    public static func configure(hidden: Bool = AppEnvironment.usesFakes()) {
        if hidden { Tips.hideAllTipsForTesting() }
        try? Tips.configure([.displayFrequency(.daily)])
    }
}

/// On My Flights once something is followed: Siri, Shortcuts and the Control Center know the next flight.
struct AskSiriTip: Tip {
    var title: Text { Text("Ask Siri about your flight") }
    var message: Text? {
        Text("Say “Is my flight on time in Soma Flight”, or add Next Flight to Control Center.")
    }
    var image: Image? { Image(systemName: "waveform") }
}

/// Over the flight sheet's "Leave by" row: the time is worked out, and the breakdown says how.
struct LeaveByTip: Tip {
    var title: Text { Text("How this time is worked out") }
    var message: Text? { Text("Tap to see the drive, the security queue and the bag drop behind it.") }
    var image: Image? { Image(systemName: "car.fill") }
}
