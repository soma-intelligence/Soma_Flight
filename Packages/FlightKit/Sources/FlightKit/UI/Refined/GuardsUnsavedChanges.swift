import SwiftUI

// Contract
// - Name: `.guardsUnsavedChanges(isDirty:isSaving:onDiscard:)`, `EnvironmentValues.requestCancel`,
//   `CancelButton` (I2).
// - Use: on the root of every editor presented as a sheet or card (notes, booking, past flight, travel
//   documents, profile, pasted import text). The editor's Cancel is `CancelButton()`, or any control that
//   calls `requestCancel()` from the environment.
// - Variants: `onDiscard` closes something other than the presentation (a card in a `CardStack`); the
//   environment's `dismiss` by default.
// - States: clean = Cancel closes at once and the swipe down works; dirty = the swipe down is blocked and
//   Cancel asks "Discard changes?"; saving = both blocked, Cancel disabled.
// - Tokens: none (system dialog).
// - A11y: the dialog's title and buttons are catalog keys; Cancel keeps its VoiceOver escape.
// - Reduce Motion: system.
// - Previews: below.

/// Closes an editor through its unsaved-changes guard. Read it with `@Environment(\.requestCancel)` and
/// call it: it closes at once when nothing changed, asks first when something did.
public struct RequestCancelAction: Sendable {
    let run: @MainActor @Sendable () -> Void

    public init(_ run: @escaping @MainActor @Sendable () -> Void) { self.run = run }

    @MainActor public func callAsFunction() { run() }
}

public extension EnvironmentValues {
    /// Set by `guardsUnsavedChanges`; nil outside a guarded editor (then `CancelButton` just dismisses).
    @Entry var requestCancel: RequestCancelAction? = nil
    /// True while a guarded editor saves, so `CancelButton` can disable itself.
    @Entry var editorIsSaving: Bool = false
}

/// The guard behind `guardsUnsavedChanges`.
struct GuardsUnsavedChanges: ViewModifier {
    var isDirty: Bool
    var isSaving: Bool
    var onDiscard: (@MainActor () -> Void)?
    @State private var asking = false
    @State private var requests = 0
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(isDirty || isSaving)
            .environment(\.editorIsSaving, isSaving)
            .environment(\.requestCancel, RequestCancelAction { [$requests] in $requests.wrappedValue += 1 })
            .onChange(of: requests) { cancel() }
            .confirmationDialog(Text("Discard changes?"), isPresented: $asking, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { close() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your edits haven't been saved.")
            }
    }

    private func cancel() {
        guard !isSaving else { return }
        if isDirty { asking = true } else { close() }
    }

    private func close() {
        if let onDiscard { onDiscard() } else { dismiss() }
    }
}

public extension View {
    /// Protects an editor's unsaved edits: no swipe-down dismissal while `isDirty` or `isSaving`, and an
    /// environment `requestCancel` that asks "Discard changes?" before closing a dirty editor.
    /// - Parameter onDiscard: how to close (a card's close); the presentation's `dismiss` when nil.
    func guardsUnsavedChanges(isDirty: Bool, isSaving: Bool = false,
                              onDiscard: (@MainActor () -> Void)? = nil) -> some View {
        modifier(GuardsUnsavedChanges(isDirty: isDirty, isSaving: isSaving, onDiscard: onDiscard))
    }
}

/// The editor's Cancel: goes through `requestCancel` (asks when dirty), disabled while saving. Outside a
/// guarded editor it dismisses.
public struct CancelButton: View {
    @Environment(\.requestCancel) private var requestCancel
    @Environment(\.editorIsSaving) private var isSaving
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        Button("Cancel", role: .cancel) {
            if let requestCancel { requestCancel() } else { dismiss() }
        }
        .disabled(isSaving)
    }
}

#Preview("Unsaved changes guard") {
    @Previewable @State var shown = true
    @Previewable @State var text = ""
    Button("Edit notes") { shown = true }
        .sheet(isPresented: $shown) {
            NavigationStack {
                TextField("Notes", text: $text, axis: .vertical)
                    .padding()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { CancelButton() }
                    }
            }
            .guardsUnsavedChanges(isDirty: !text.isEmpty)
        }
}
