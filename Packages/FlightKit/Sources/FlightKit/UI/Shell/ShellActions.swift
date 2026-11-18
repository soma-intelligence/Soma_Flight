import SwiftUI

public extension EnvironmentValues {
    /// Opens sign-in as a sheet over what is on screen (E3), so open editors keep their text. Set by
    /// `SignInGate`; nil outside it (previews, tests). Banners pass it as `ErrorBanner(signIn:)`.
    @Entry var requestSignIn: (@MainActor () -> Void)? = nil

    /// Bumped when the user taps the tab that is already selected and no card is open (I10): the tab's
    /// scroll view goes back to its top. `ScreenScroll` reads it.
    @Entry var scrollToTopSignal: Int = 0
}

/// What tapping the selected tab again does (I10): close the open cards first, else scroll the list to its top.
public enum TabReselect: Equatable, Sendable {
    case popCards
    case scrollToTop

    public static func action(cardsOpen: Bool) -> TabReselect { cardsOpen ? .popCards : .scrollToTop }
}
