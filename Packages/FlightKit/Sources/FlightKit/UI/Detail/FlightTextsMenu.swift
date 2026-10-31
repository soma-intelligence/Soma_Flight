import SwiftUI

private struct FlightTextsKey: EnvironmentKey {
    static var defaultValue: FlightTextsModel? { nil }
}

public extension EnvironmentValues {
    /// The flight sheet's in-flight texts switch; `FlightScreen` sets it for a followed flight, nil hides it.
    var flightTexts: FlightTextsModel? {
        get { self[FlightTextsKey.self] }
        set { self[FlightTextsKey.self] = newValue }
    }
}

/// The More menu's "Text Me Updates In Flight": this flight's arrival news by text from boarding to the
/// gate, over the account's In-Flight Texts mode. Shown once a number is verified in Settings.
struct FlightTextsMenuItem: View {
    var model: FlightTextsModel?

    var body: some View {
        if let model, model.isShown {
            Toggle(isOn: Binding(get: { model.isOn }, set: { on in Task { await model.set(on) } })) {
                Label("Text Me Updates In Flight", systemImage: "message")
            }
        }
    }
}
