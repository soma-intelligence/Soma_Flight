import SwiftUI

/// The words of Settings > Travel Documents. No SwiftUI here, so the tests read the exact text.
enum TravelDocumentsCopy {
    static let footnote = "Encrypted on your device before it syncs."
    static let syncTitle = "Sync"
    static let syncOff = "This device only"
    static let syncOn = "Encrypted, on all your devices"
    static let deleteTitle = "Delete all travel documents?"
    static let deleteMessage = "This removes them from all your devices. It can't be undone."

    /// "Air France · Flying Blue", or the airline's code when the list does not know it.
    static func loyaltyTitle(_ n: LoyaltyNumber, airline: Airline?) -> String {
        let name = airline?.name ?? n.airline
        return n.programme.map { "\(name) · \($0)" } ?? name
    }

    /// "France · expires 12 Mar 2027".
    static func passportSubtitle(_ p: TravelProfile, country: Country?) -> String? {
        let parts = [country?.name ?? p.passportCountry,
                     TravelDocumentRules.day(p.passportExpires).map { "expires \(TravelDocumentRules.dayText($0))" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Settings > Travel Documents: loyalty numbers per airline, the passport, the Known Traveler and Redress
/// numbers, the sync switch (on by default) and a way to remove everything.
public struct TravelDocumentsView: View {
    var store: TravelDocumentsStore
    var onDone: (() -> Void)?

    @Environment(\.reference) private var reference
    @Environment(\.scenePhase) private var phase
    @State private var editing: TravelDocumentEditor.Subject?
    @State private var confirmingDelete = false
    @State private var copied: String?

    public init(store: TravelDocumentsStore, onDone: (() -> Void)? = nil) {
        self.store = store; self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onDone {
                HStack {
                    Spacer()
                    Button("Done", action: onDone)
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.top, 8)
            }
            ScreenTitle("Travel Documents")
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.top, onDone == nil ? 22 : 0)
                .scaledPadding(.bottom, 16)
            ScreenScroll(scrolls: true) { content }
        }
        .background(Theme.background)
        .onAppear { store.load(); Task { await store.syncWithCloud() } }
        .onDisappear { store.hide() }
        // Hidden numbers never stay in memory behind the app switcher.
        .onChange(of: phase) { _, new in if new != .active { store.hide() } }
        .sheet(item: $editing) { subject in
            TravelDocumentEditor(subject: subject, store: store, onClose: { editing = nil })
                .presentationDetents([.medium, .large])
                #if os(macOS)
                .frame(minWidth: 400, minHeight: 420)
                #endif
        }
        .confirmationDialog(TravelDocumentsCopy.deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { store.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(TravelDocumentsCopy.deleteMessage)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure = store.failure {
                Text(failure).scaledFont(13).foregroundStyle(Theme.late).scaledPadding(.horizontal, 16).scaledPadding(.top, 8)
            }
            group("Loyalty") {
                ForEach(store.profile.loyalty) { n in
                    SettingsRow(icon: "star.circle.fill",
                                title: TravelDocumentsCopy.loyaltyTitle(n, airline: reference.airline(n.airline)),
                                subtitle: n.number, action: { editing = .loyalty(n) }) {
                        copyButton(n.number, label: "Copy \(n.number)") { Clipboard.copy(n.number, sensitive: false) }
                    }
                }
                SettingsRow(icon: "plus.circle.fill", title: "Add Loyalty Number", last: true,
                            action: { editing = .loyalty(nil) }) { EmptyView() }
            }
            group("Documents") {
                SettingsRow(icon: "person.text.rectangle.fill", title: "Passport",
                            subtitle: passportLine, action: { editing = .passport }) {
                    hiddenAccessory(.passport)
                }
                SettingsRow(icon: "checkmark.shield.fill", title: TravelDocumentKind.knownTraveler.title,
                            subtitle: store.display(.knownTraveler), action: { editing = .knownTraveler }) {
                    hiddenAccessory(.knownTraveler)
                }
                SettingsRow(icon: "number.circle.fill", title: TravelDocumentKind.redress.title,
                            subtitle: store.display(.redress), last: true,
                            action: { editing = .redress }) {
                    hiddenAccessory(.redress)
                }
            }
            if !store.identityKinds.isEmpty {
                Button {
                    if store.isRevealed { store.hide() } else { Task { await store.reveal() } }
                } label: {
                    Label(store.isRevealed ? "Hide Numbers" : "Show Numbers",
                          systemImage: store.isRevealed ? "eye.slash" : "faceid")
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .scaledPadding(.top, 16)
            }
            group("Sync") {
                SettingsRow(icon: "icloud.fill", title: TravelDocumentsCopy.syncTitle,
                            subtitle: store.syncsWithICloud ? TravelDocumentsCopy.syncOn : TravelDocumentsCopy.syncOff,
                            last: true) {
                    Toggle(TravelDocumentsCopy.syncTitle,
                           isOn: Binding(get: { store.syncsWithICloud }, set: { on in Task { await store.setSync(on) } }))
                        .labelsHidden()
                        .tint(Theme.accent)
                }
                .accessibilityElement(children: .combine)
            }
            if !store.profile.isEmpty || !store.identityKinds.isEmpty {
                group("Remove") {
                    SettingsRow(icon: "trash.fill", title: "Delete All Travel Documents", tone: .destructive, last: true,
                                action: { confirmingDelete = true }) { EmptyView() }
                }
            }
            Text(TravelDocumentsCopy.footnote)
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 8)
            if let copied {
                Text("Copied \(copied)").scaledFont(13).foregroundStyle(Theme.secondary)
                    .scaledPadding(.horizontal, 16).scaledPadding(.top, 4)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .scaledPadding(.bottom, 32)
    }

    private var passportLine: String? {
        let summary = TravelDocumentsCopy.passportSubtitle(store.profile,
                                                           country: store.profile.passportCountry.flatMap(country))
        let number = store.display(.passport)
        let parts = [number, summary].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func country(_ code: String) -> Country? { reference.countries.first { $0.id.uppercased() == code } }

    @ViewBuilder private func hiddenAccessory(_ kind: TravelDocumentKind) -> some View {
        if store.identityKinds.contains(kind) {
            copyButton(kind.title, label: "Copy \(kind.title)") {
                Task {
                    if let v = await store.copyValue(kind) { Clipboard.copy(v, sensitive: true); copied = kind.title }
                }
            }
        } else {
            RowChevron()
        }
    }

    private func copyButton(_ what: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            if what.allSatisfy({ $0.isNumber || $0.isLetter }) { copied = what }
        } label: {
            Image(systemName: "doc.on.doc")
                .scaledFont(16, weight: .medium)
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        SettingsSection(title) { rows() }
    }
}

/// Adds or edits one travel document: a loyalty number (airline, number, programme name), the passport
/// (number, country, expiry) or a Known Traveler or Redress number. Saving an invalid number says why.
struct TravelDocumentEditor: View {
    enum Subject: Identifiable, Hashable {
        case loyalty(LoyaltyNumber?)
        case passport, knownTraveler, redress

        var id: String {
            switch self {
            case .loyalty(let n): "loyalty-\(n?.id.uuidString ?? "new")"
            case .passport: "passport"
            case .knownTraveler: "ktn"
            case .redress: "redress"
            }
        }
    }

    var subject: Subject
    var store: TravelDocumentsStore
    var onClose: () -> Void

    @Environment(\.reference) private var reference
    @State private var number = ""
    @State private var airline = ""
    @State private var programme = ""
    @State private var country = ""
    @State private var expires = Date.now
    @State private var hasExpiry = false
    @State private var invalid = false
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CardTitle(title).scaledPadding(.trailing, 44)
                fields
                if invalid {
                    Text(invalidText).scaledFont(13).foregroundStyle(Theme.late)
                }
                Button(action: save) {
                    Text(saving ? "Saving…" : "Save")
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .scaledPadding(.vertical, 14)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .disabled(saving)
                if case .loyalty(let n?) = subject {
                    Button("Delete This Number", role: .destructive) { store.deleteLoyalty(n.id); onClose() }
                        .frame(maxWidth: .infinity)
                }
            }
            .scaledPadding(.horizontal, Theme.gutter)
            .scaledPadding(.vertical, 24)
        }
        .background(Theme.background)
        .overlay(alignment: .topTrailing) { CloseButton(action: onClose) }
        .task { await prefill() }
    }

    private var title: String {
        switch subject {
        case .loyalty(let n): n == nil ? "Add Loyalty Number" : "Loyalty Number"
        case .passport: "Passport"
        case .knownTraveler: TravelDocumentKind.knownTraveler.title
        case .redress: TravelDocumentKind.redress.title
        }
    }

    private var kind: TravelDocumentKind {
        switch subject {
        case .loyalty: .loyalty
        case .passport: .passport
        case .knownTraveler: .knownTraveler
        case .redress: .redress
        }
    }

    private var invalidText: String {
        switch kind {
        case .loyalty: "Pick an airline and enter a number of 4 to 20 letters and digits."
        case .passport: "A passport number has 5 to 12 letters and digits."
        case .knownTraveler: "A Known Traveler Number has 8 to 10 letters and digits."
        case .redress: "A Redress Number has 6 to 13 digits."
        }
    }

    @ViewBuilder private var fields: some View {
        if case .loyalty = subject {
            field("Airline code or name", text: $airline)
            if let match = airlineMatch {
                Text(match.name).scaledFont(13).foregroundStyle(Theme.secondary)
            }
            field("Number", text: $number)
            field("Programme name (optional)", text: $programme)
        } else {
            field(kind == .passport ? "Passport number" : "Number", text: $number, secure: true)
            if kind == .passport {
                field("Issuing country code, FR or US", text: $country)
                Toggle("Expiry date", isOn: $hasExpiry).tint(Theme.accent)
                if hasExpiry {
                    DatePicker("Expires", selection: $expires, displayedComponents: .date)
                }
            }
            Text("Leave the number empty to remove it.").scaledFont(13).foregroundStyle(Theme.secondary)
        }
    }

    private func field(_ prompt: String, text: Binding<String>, secure: Bool = false) -> some View {
        TextField(prompt, text: text)
            .scaledFont(17)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.characters)
            .textContentType(secure ? .oneTimeCode : nil)
            #endif
            .scaledPadding(.all, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card.opacity(0.5)))
    }

    /// The airline typed: an ICAO or IATA code, else the first name that starts with the text.
    private var airlineMatch: Airline? {
        let t = airline.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return nil }
        if let a = reference.airline(t.uppercased()) { return a }
        return reference.airlines.first { $0.name.lowercased().hasPrefix(t.lowercased()) }
    }

    private func prefill() async {
        switch subject {
        case .loyalty(let n?):
            airline = n.airline; number = n.number; programme = n.programme ?? ""
        case .loyalty(nil):
            break
        case .passport:
            country = store.profile.passportCountry ?? ""
            if let d = TravelDocumentRules.day(store.profile.passportExpires) { expires = d; hasExpiry = true }
            if store.identityKinds.contains(.passport), await store.reveal() { number = store.display(.passport) ?? "" }
        case .knownTraveler, .redress:
            if store.identityKinds.contains(kind), await store.reveal() { number = store.display(kind) ?? "" }
        }
    }

    private func save() {
        saving = true
        Task {
            let ok: Bool
            switch subject {
            case .loyalty(let n):
                if let a = airlineMatch {
                    ok = store.saveLoyalty(id: n?.id ?? UUID(), airline: a.id, number: number, programme: programme)
                } else { ok = false }
            case .passport:
                ok = await store.savePassport(number: number, country: country, expires: hasExpiry ? expires : nil)
            case .knownTraveler, .redress:
                ok = await store.saveHidden(kind, number)
            }
            saving = false
            if ok { onClose() } else { invalid = true }
        }
    }
}

#Preview("Travel Documents") {
    TravelDocumentsView(store: .preview())
}
