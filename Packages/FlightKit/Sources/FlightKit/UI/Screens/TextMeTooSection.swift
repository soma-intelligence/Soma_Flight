import SwiftUI

/// Settings > Notifications > Text Me Too: the flight alerts also by text from the Soma line, for
/// travellers who keep notifications off and for airline Wi-Fi that only lets messaging apps through
/// (In-Flight Texts). Number, six digit code, the two switches, Forget My Number. The number is used for
/// flight alerts only, which the section says where the number is typed.
struct TextMeTooSection: View {
    @Bindable var store: TextAlertsStore
    @FocusState private var focus: Field?

    enum Field { case phone, code }

    static let privacyLine = "Your number is used for flight alerts only. It is never shared, sold or used for anything else. Reply STOP to any text to stop them."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CapsHeader("Text Me Too")
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 34)
                .scaledPadding(.bottom, 8)
            Hairline().scaledPadding(.horizontal, 16)
            switch store.step {
            case .unavailable: unavailable
            case .number: numberStep
            case .code: codeStep
            case .verified: verifiedStep
            }
            Hairline().scaledPadding(.horizontal, 16)
            if let error = store.error {
                Text(error.message)
                    .scaledFont(13)
                    .foregroundStyle(Theme.veryLate)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.top, 8)
            }
            Text(store.step == .verified ? Self.privacyLine : "Flight alerts by iMessage or text, next to the push. \(Self.privacyLine)")
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 8)
        }
        .task { if !store.hasLoaded { await store.load() } }
    }

    private var unavailable: some View {
        SettingsRow(icon: "message", title: "Text Me Too", subtitle: "Coming soon: flight alerts by text, also in the air on messaging-only Wi-Fi.",
                    last: true) { EmptyView() }
            .accessibilityElement(children: .combine)
    }

    private var numberStep: some View {
        VStack(spacing: 0) {
            SettingsRow(icon: "phone", title: "Mobile Number",
                        subtitle: store.status.optedOut ? "You replied STOP. Verify the number again to get texts." : nil) {
                EmptyView()
            }
            HStack(spacing: 12) {
                TextField("+1 415 555 0100", text: $store.phoneDraft)
                    .textContentType(.telephoneNumber)
                    #if os(iOS)
                    .keyboardType(.phonePad)
                    #endif
                    .scaledFont(17)
                    .focused($focus, equals: .phone)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .accessibilityLabel("Mobile number with country code")
                Button("Send Code", action: send)
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                    .disabled(store.phoneDraft.trimmingCharacters(in: .whitespaces).isEmpty || store.isWorking)
            }
            .scaledPadding(.leading, 60)
            .scaledPadding(.trailing, 16)
            .frame(minHeight: 50)
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(icon: "number", title: "Enter the Code",
                        subtitle: "Sent to \(store.status.phone ?? "your number"). It expires in 10 minutes.") {
                Button("Change", action: store.changeNumber)
                    .scaledFont(15).foregroundStyle(Theme.accent).buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                TextField("6 digits", text: $store.codeDraft)
                    .textContentType(.oneTimeCode)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .scaledFont(17).monospacedDigit()
                    .focused($focus, equals: .code)
                    .onSubmit(check)
                    .accessibilityLabel("Six digit code")
                Button("Verify", action: check)
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                    .disabled(store.codeDraft.filter(\.isNumber).count != 6 || store.isWorking)
            }
            .scaledPadding(.leading, 60)
            .scaledPadding(.trailing, 16)
            .frame(minHeight: 50)
            if let message = store.codeMessage {
                Text(message)
                    .scaledFont(13).foregroundStyle(Theme.late)
                    .scaledPadding(.leading, 60).scaledPadding(.bottom, 10)
            }
        }
        .onAppear { focus = .code }
    }

    private var verifiedStep: some View {
        VStack(spacing: 0) {
            SettingsRow(icon: "message", title: "Text Me Too",
                        subtitle: "Delays of 30 minutes or more, gate changes, cancellations, diversions and connections at risk, to \(store.status.phone ?? "your number").") {
                Toggle("Text Me Too", isOn: Binding(get: { store.status.enabled },
                                                     set: { on in Task { await store.setEnabled(on) } }))
                    .labelsHidden().tint(Theme.accent).disabled(store.isWorking)
            }
            .accessibilityElement(children: .combine)
            SettingsRow(icon: "airplane", title: "In-Flight Texts",
                        subtitle: "From boarding to the gate: arrival delays, diversions, arrival gate, baggage belt, your connection and the landing. Works on airline Wi-Fi that only allows messaging apps.") {
                Toggle("In-Flight Texts", isOn: Binding(get: { store.status.inFlight },
                                                         set: { on in Task { await store.setInFlight(on) } }))
                    .labelsHidden().tint(Theme.accent).disabled(store.isWorking)
            }
            .accessibilityElement(children: .combine)
            SettingsRow(icon: "trash", title: "Forget My Number", tint: Theme.veryLate, last: true,
                        action: { Task { await store.forget() } }) { EmptyView() }
        }
    }

    private func send() { Task { await store.sendCode(); if store.step == .code { focus = .code } } }
    private func check() { Task { await store.checkCode() } }
}

#if DEBUG
struct TextMeTooPreview: View {
    var status = TextAlertsStatus(available: true)
    @State private var store: TextAlertsStore?

    var body: some View {
        ScrollView {
            if let store { TextMeTooSection(store: store) }
        }
        .background(Theme.background)
        .task {
            let s = TextAlertsStore(service: FakeTextAlertsService(status))
            s.seed(status)
            store = s
        }
    }
}

#Preview("Text Me Too, number") { TextMeTooPreview().preferredColorScheme(.dark) }
#Preview("Text Me Too, verified") {
    TextMeTooPreview(status: TextAlertsStatus(available: true, phone: "+14155550100", verified: true, enabled: true,
                                              inFlight: true))
        .preferredColorScheme(.dark)
}
#endif
