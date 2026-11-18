import SwiftUI

/// The words of Settings > Travel Documents. No SwiftUI here, so the tests read the exact text.
enum TravelDocumentsCopy {
    static let footnote = "Encrypted on your device before it syncs."
    static let syncTitle = "Sync"
    static let syncOff = "This device only"
    static let syncOn = "Encrypted, on all your devices"
    /// The account has not taken the last change yet (E13).
    static let syncPending = "Not synced yet"
    /// The last send failed (E13); the row under it retries.
    static let syncFailed = "Not synced yet. The last try didn't go through."
    static let syncRetry = "Try Syncing Again"
    /// A save that the Keychain or Face ID refused, as opposed to a number that does not read (I3).
    static let saveFailed = "Couldn't save on this device. Nothing was changed. Try again."
    static let removeTitle = "Remove this number?"
    static let removeMessage = "It goes from all your devices. This can't be undone."

    /// The sync row's line for `state` (E13): "on all your devices" only once the account has the documents.
    static func syncLine(_ state: TravelDocumentsStore.SyncState) -> String {
        switch state {
        case .off: syncOff
        case .synced: syncOn
        case .pending: syncPending
        case .failed: syncFailed
        }
    }
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
    /// The X of the modal header when the page opens over Settings (the phone's card stack).
    var onClose: (() -> Void)?

    @Environment(\.reference) private var reference
    @Environment(\.metricsScale) private var scale
    @Environment(\.scenePhase) private var phase
    @State private var editing: TravelDocumentEditor.Subject?
    @State private var confirmingDelete = false
    @State private var copied: String?

    /// - Parameters:
    ///   - onDone: closes the page from its own sheet (the Mac).
    ///   - onClose: closes the page from Settings' card stack (the phone).
    public init(store: TravelDocumentsStore, onDone: (() -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.store = store; self.onDone = onDone; self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScreenScroll(scrolls: true) { content }
        }
        .background(Theme.background)
        .onAppear { store.load(); Task { await store.syncWithCloud() } }
        .onDisappear { store.hide() }
        // Hidden numbers never stay in memory behind the app switcher.
        .onChange(of: phase) { _, new in if new != .active { store.hide() } }
        .sheet(item: $editing) { subject in
            TravelDocumentEditor(subject: subject, store: store, onClose: { editing = nil })
                .presentationDetents([.large])
                #if os(macOS)
                .frame(minWidth: 400, minHeight: 420)
                #endif
        }
        .confirmationDialog(TravelDocumentsCopy.deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { store.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ui: TravelDocumentsCopy.deleteMessage)
        }
    }

    /// The modal header (R5): the title centred, the glass X on the left. Each number saves in its own editor,
    /// so the page has no Done. Pushed in a navigation stack (the Mac Profil), the stack's back button closes it.
    @ViewBuilder private var header: some View {
        if let close = onClose ?? onDone {
            SheetHeader(.modal(title: "Travel Documents", leading: .close(close)))
                .scaledPadding(.top, 8)
        } else {
            Text("Travel Documents")
                .themeFont(.sectionTitle)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, minHeight: Theme.metric(56, scale))
                .scaledPadding(.top, 8)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure = store.failure {
                Text(ui: failure).themeFont(.sectionSubtitle).foregroundStyle(Theme.lateText)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaledPadding(.horizontal, Theme.gutter + 16).scaledPadding(.top, 8)
            }
            group("Loyalty") {
                ForEach(store.profile.loyalty) { n in
                    SettingsRow(icon: "star.circle.fill",
                                title: TravelDocumentsCopy.loyaltyTitle(n, airline: reference.airline(n.airline)),
                                subtitle: n.number, action: { editing = .loyalty(n) }) {
                        copyButton(n.number, label: "Copy \(n.number)") { Clipboard.copy(n.number, sensitive: false) }
                    }
                }
                SettingsRow(icon: "plus.circle.fill", title: "Add Loyalty Number", last: true, actionTitle: true,
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
                    // The secondary capsule button: the accent on the pill colour, 50 pt tall.
                    Label(store.isRevealed ? "Hide Numbers" : "Show Numbers",
                          systemImage: store.isRevealed ? "eye.slash" : "faceid")
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(Theme.accent)
                        .scaledPadding(.horizontal, 24)
                        .frame(minWidth: Theme.metric(200, scale), minHeight: Theme.metric(50, scale))
                        .background(Capsule().fill(Theme.pill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .scaledPadding(.top, 16)
            }
            group("Sync") {
                SettingsRow(icon: "icloud.fill", title: TravelDocumentsCopy.syncTitle,
                            subtitle: TravelDocumentsCopy.syncLine(store.syncState),
                            last: store.syncState != .failed) {
                    Toggle(TravelDocumentsCopy.syncTitle,
                           isOn: Binding(get: { store.syncsWithICloud }, set: { on in Task { await store.setSync(on) } }))
                        .labelsHidden()
                        .tint(Theme.accent)
                }
                .accessibilityElement(children: .combine)
                if store.syncState == .failed {
                    SettingsRow(icon: "arrow.clockwise", title: TravelDocumentsCopy.syncRetry, last: true,
                                actionTitle: true, action: { Task { await store.retrySync() } }) { EmptyView() }
                }
            }
            if !store.profile.isEmpty || !store.identityKinds.isEmpty {
                group("Remove") {
                    SettingsRow(icon: "trash.fill", title: "Delete All Travel Documents", tone: .destructive, last: true,
                                action: { confirmingDelete = true }) { EmptyView() }
                }
            }
            Text(ui: TravelDocumentsCopy.footnote)
                .themeFont(.sectionSubtitle)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.horizontal, Theme.gutter + 16)
                .scaledPadding(.top, 8)
            if let copied {
                Text("Copied \(copied)").themeFont(.sectionSubtitle).foregroundStyle(Theme.secondary)
                    .scaledPadding(.horizontal, Theme.gutter + 16).scaledPadding(.top, 4)
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

/// What saving an editor did (I3): stored, a number that does not read, a write the device refused, or an
/// empty number that would remove a kept one and needs a yes first.
enum TravelDocumentSaveOutcome: Equatable {
    case saved, invalid, failed, confirmRemove
}

/// The editor's fields and its save, apart from the view so the tests can drive it (I3).
@MainActor @Observable
final class TravelDocumentEditorModel {
    let subject: TravelDocumentEditor.Subject
    var number = "" { didSet { if number != oldValue { error = nil } } }
    var airline = "" { didSet { if airline != oldValue { error = nil } } }
    var programme = ""
    /// ISO 3166 code, "" for none.
    var country = ""
    var expires = Date.now
    var hasExpiry = false
    /// Why the last save did not go through; cleared as soon as the user types (I3).
    private(set) var error: TravelDocumentSaveOutcome?
    private(set) var saving = false
    /// The hidden number was read (Face ID passed), so an empty field really means "remove it".
    private(set) var numberLoaded = false
    private var initial: Snapshot?

    struct Snapshot: Equatable {
        var number: String, airline: String, programme: String, country: String, expires: Date?
    }

    init(subject: TravelDocumentEditor.Subject) { self.subject = subject }

    var kind: TravelDocumentKind {
        switch subject {
        case .loyalty: .loyalty
        case .passport: .passport
        case .knownTraveler: .knownTraveler
        case .redress: .redress
        }
    }

    private var snapshot: Snapshot {
        Snapshot(number: number, airline: airline, programme: programme, country: country,
                 expires: hasExpiry ? expires : nil)
    }

    /// Something changed since the editor filled in (I2).
    var isDirty: Bool { initial.map { $0 != snapshot } ?? false }

    /// The number as it will be stored ("ab 123-456" saves as "AB123456"), shown before saving when it
    /// differs from what was typed; nil when it already reads the same or does not read at all.
    var normalizedPreview: String? {
        let typed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, let v = TravelDocumentRules.validated(typed, as: kind), v != typed else { return nil }
        return v
    }

    /// Fills the fields from the store: the hidden number only after Face ID.
    func prefill(from store: TravelDocumentsStore) async {
        switch subject {
        case .loyalty(let n?):
            airline = n.airline; number = n.number; programme = n.programme ?? ""; numberLoaded = true
        case .loyalty(nil):
            numberLoaded = true
        case .passport:
            country = store.profile.passportCountry ?? ""
            if let d = TravelDocumentRules.day(store.profile.passportExpires) { expires = d; hasExpiry = true }
            await loadHidden(.passport, from: store)
        case .knownTraveler, .redress:
            await loadHidden(kind, from: store)
        }
        initial = snapshot
        error = nil
    }

    private func loadHidden(_ kind: TravelDocumentKind, from store: TravelDocumentsStore) async {
        if !store.identityKinds.contains(kind) { numberLoaded = true; return }
        if await store.reveal() { number = store.display(kind) ?? ""; numberLoaded = true }
    }

    /// Saves to `store`. `airlineID` is the airline the typed text names (loyalty only). An empty number that
    /// would remove a kept one returns `.confirmRemove` until `confirmedRemove` is true.
    func save(to store: TravelDocumentsStore, airlineID: String?, confirmedRemove: Bool = false) async
        -> TravelDocumentSaveOutcome {
        guard !saving else { return .failed }
        let typed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        // A number that does not read never reaches the store: that is `.invalid`, not a failure.
        if !typed.isEmpty, TravelDocumentRules.validated(typed, as: kind) == nil { return finish(.invalid) }
        if kind == .loyalty, airlineID == nil || typed.isEmpty { return finish(.invalid) }
        let removes = kind != .loyalty && typed.isEmpty && numberLoaded && store.identityKinds.contains(kind)
        if removes, !confirmedRemove { return .confirmRemove }
        saving = true
        defer { saving = false }
        let ok: Bool
        switch subject {
        case .loyalty(let n):
            ok = store.saveLoyalty(id: n?.id ?? UUID(), airline: airlineID ?? "", number: typed, programme: programme)
        case .passport:
            // Face ID refused earlier: the field never showed the number, so an empty one keeps it.
            let value: String? = typed.isEmpty && !numberLoaded ? nil : typed
            ok = await store.savePassport(number: value, country: country, expires: hasExpiry ? expires : nil)
        case .knownTraveler, .redress:
            if typed.isEmpty, !store.identityKinds.contains(kind) || !numberLoaded { return finish(.saved) }
            ok = await store.saveHidden(kind, typed)
        }
        return finish(ok ? .saved : .failed)
    }

    private func finish(_ outcome: TravelDocumentSaveOutcome) -> TravelDocumentSaveOutcome {
        error = outcome == .saved ? nil : outcome
        return outcome
    }
}

/// Adds or edits one travel document: a loyalty number (airline, number, programme name), the passport
/// (number, country, expiry) or a Known Traveler or Redress number. The modal header (R5, I12): Cancel on the
/// left asks before dropping a change (I2), Done on the right saves. Each field has a persistent label (I5).
/// A number that does not read says how it should look; a save the device refused says so apart (I3).
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

    enum Field: Hashable { case airline, number, programme }

    var subject: Subject
    var store: TravelDocumentsStore
    var onClose: () -> Void

    @Environment(\.reference) private var reference
    @State private var model: TravelDocumentEditorModel
    @State private var confirmingRemove = false
    @State private var confirmingDelete = false
    @FocusState private var focus: Field?

    init(subject: Subject, store: TravelDocumentsStore, onClose: @escaping () -> Void) {
        self.subject = subject; self.store = store; self.onClose = onClose
        _model = State(initialValue: TravelDocumentEditorModel(subject: subject))
    }

    var body: some View {
        VStack(spacing: 0) {
            TravelDocumentEditorHeader(title: title, onDone: { save() }, doneDisabled: model.saving)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.metric(Theme.Space.md, scale)) {
                    fields
                    if model.error == .failed {
                        Label { Text(ui: store.failure ?? TravelDocumentsCopy.saveFailed) } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .scaledFont(13, weight: .medium)
                        .foregroundStyle(Theme.lateText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.saving {
                        ProgressView().frame(maxWidth: .infinity).accessibilityLabel("Saving")
                    }
                    if case .loyalty(let n?) = subject {
                        Button("Delete This Number", role: .destructive) { confirmingDelete = true }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .confirmDestructive(isPresented: $confirmingDelete, title: "Delete this loyalty number?",
                                                message: TravelDocumentsCopy.removeMessage,
                                                actionTitle: "Delete This Number") {
                                store.deleteLoyalty(n.id); onClose()
                            }
                    }
                }
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.vertical, Theme.Space.md)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.background)
        .keyboardDoneBar()
        .guardsUnsavedChanges(isDirty: model.isDirty, isSaving: model.saving, onDiscard: onClose)
        .confirmDestructive(isPresented: $confirmingRemove, title: TravelDocumentsCopy.removeTitle,
                            message: TravelDocumentsCopy.removeMessage, actionTitle: "Remove Number") {
            save(confirmedRemove: true)
        }
        .task { await model.prefill(from: store) }
    }

    @Environment(\.metricsScale) private var scale

    private var title: String {
        switch subject {
        case .loyalty(let n): n == nil ? "Add Loyalty Number" : "Loyalty Number"
        case .passport: "Passport"
        case .knownTraveler: TravelDocumentKind.knownTraveler.title
        case .redress: TravelDocumentKind.redress.title
        }
    }

    private var invalidText: String {
        switch model.kind {
        case .loyalty: "A loyalty number has 4 to 20 letters and digits."
        case .passport: "A passport number has 5 to 12 letters and digits."
        case .knownTraveler: "A Known Traveler Number has 8 to 10 letters and digits."
        case .redress: "A Redress Number has 6 to 13 digits."
        }
    }

    /// The error under the number field: only for a number that does not read.
    private var numberError: String? {
        guard model.error == .invalid else { return nil }
        if model.kind == .loyalty, airlineMatch == nil { return nil }
        return model.number.trimmingCharacters(in: .whitespaces).isEmpty && model.kind == .loyalty
            ? "Enter the number." : invalidText
    }

    /// Under the number: the stored form when it differs from what was typed (I3), else a hint.
    private var numberFootnote: String? {
        if let v = model.normalizedPreview { return UIText.localized("Saves as") + " " + v }
        return model.kind == .loyalty ? nil : "Leave the number empty to remove it."
    }

    @ViewBuilder private var fields: some View {
        @Bindable var model = model
        if case .loyalty = subject {
            FormField("Airline", text: $model.airline, prompt: "AF or Air France",
                      error: model.error == .invalid && airlineMatch == nil
                        ? "Type an airline's code or name, like AF or Air France." : nil,
                      footnote: airlineMatch?.name,
                      capitalization: .words, autocorrect: false,
                      focus: $focus, field: .airline, next: .number)
            FormField("Number", text: $model.number, prompt: "1234567890", error: numberError,
                      footnote: numberFootnote, keyboard: .ascii, capitalization: .characters, autocorrect: false,
                      focus: $focus, field: .number, next: .programme)
            FormField("Programme name (optional)", text: $model.programme, prompt: "Flying Blue",
                      capitalization: .words, submitLabel: .done,
                      focus: $focus, field: .programme, onSubmit: { save() })
        } else {
            FormField(model.kind == .passport ? "Passport number" : "Number", text: $model.number,
                      prompt: prompt, error: numberError, footnote: numberFootnote,
                      keyboard: model.kind == .redress ? .number : .ascii,
                      capitalization: .characters, autocorrect: false, submitLabel: .done,
                      focus: $focus, field: .number, onSubmit: { save() })
            if model.kind == .passport {
                Picker(selection: $model.country) {
                    Text("None").tag("")
                    ForEach(TravelDocumentCountries.all, id: \.code) { c in
                        Text(verbatim: c.name).tag(c.code)
                    }
                } label: {
                    Text("Issuing country")
                }
                .pickerStyle(.menu)
                .tint(Theme.accentText)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                Toggle("Expiry date", isOn: $model.hasExpiry).tint(Theme.accent)
                if model.hasExpiry {
                    DatePicker("Expires", selection: $model.expires, displayedComponents: .date)
                }
            }
        }
    }

    private var prompt: String {
        switch model.kind {
        case .passport: "19AB12345"
        case .knownTraveler: "TT1234567"
        case .redress: "1234567"
        case .loyalty: ""
        }
    }

    /// The airline typed: an ICAO or IATA code, else the first name that starts with the text.
    private var airlineMatch: Airline? {
        let t = model.airline.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return nil }
        if let a = reference.airline(t.uppercased()) { return a }
        return reference.airlines.first { $0.name.lowercased().hasPrefix(t.lowercased()) }
    }

    private func save(confirmedRemove: Bool = false) {
        focus = nil
        Task {
            switch await model.save(to: store, airlineID: airlineMatch?.id, confirmedRemove: confirmedRemove) {
            case .saved: onClose()
            case .confirmRemove: confirmingRemove = true
            case .invalid, .failed: break
            }
        }
    }
}

/// The editor's modal header: Cancel on the left through `guardsUnsavedChanges`, Done on the right saves.
private struct TravelDocumentEditorHeader: View {
    var title: String
    var onDone: () -> Void
    var doneDisabled: Bool
    @Environment(\.requestCancel) private var requestCancel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetHeader(.modal(title: title, leading: .cancel { if let requestCancel { requestCancel() } else { dismiss() } },
                           onDone: onDone, doneDisabled: doneDisabled))
            .scaledPadding(.top, 8)
    }
}

/// Every region with a two-letter ISO code, named in the app's language, for the passport's country.
enum TravelDocumentCountries {
    struct Entry: Hashable { var code: String; var name: String }

    static let all: [Entry] = {
        let locale = Locale.current
        return Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
            .compactMap { code in locale.localizedString(forRegionCode: code).map { Entry(code: code.uppercased(), name: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()
}

#Preview("Travel Documents") {
    TravelDocumentsView(store: .preview())
}
