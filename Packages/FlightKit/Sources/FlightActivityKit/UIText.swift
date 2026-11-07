import Foundation
import SwiftUI

public extension Text {
    /// Text the app built as a String (a title handed to a shared row, a status line), shown in the user's
    /// language when the app's Localizable catalog has it, else as it is. `Text("literal")` is looked up on
    /// its own; a String is not, so the shared views go through here.
    init<S: StringProtocol>(ui s: S) {
        self.init(verbatim: UIText.localized(String(s)))
    }
}

public enum UIText {
    /// The catalog's translation of `s` in the app's (or extension's) main bundle, `s` itself when none.
    public static func localized(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        return Bundle.main.localizedString(forKey: s, value: s, table: nil)
    }
}
