import SwiftUI

// Contract
// - Name: `.confirmDestructive(isPresented:title:message:actionTitle:action:)` and the item variant
//   `.confirmDestructive(item:title:message:actionTitle:action:)` (I1, I3).
// - Use: any action that cannot be undone (delete a Passport flight, forget a number, remove a loyalty
//   number). An action that can be undone gets an Undo toast instead, not this dialog.
// - Variants: a Bool trigger, or an optional item (the row whose delete was picked).
// - States: hidden, shown; the destructive button runs `action`, Cancel only closes.
// - Tokens: none (system confirmation dialog: red destructive role, bold Cancel).
// - A11y: title always visible; strings go through the catalog (`Text(ui:)`).
// - Reduce Motion: system presentation.
// - Previews: below.

public extension View {
    /// A confirmation dialog for an irreversible action: `title` (visible), an optional `message` naming
    /// what is lost, a red `actionTitle` button that runs `action`, and Cancel.
    func confirmDestructive(isPresented: Binding<Bool>, title: String, message: String? = nil,
                            actionTitle: String, action: @escaping () -> Void) -> some View {
        confirmationDialog(Text(ui: title), isPresented: isPresented, titleVisibility: .visible) {
            Button(role: .destructive, action: action) { Text(ui: actionTitle) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let message { Text(ui: message) }
        }
    }

    /// `confirmDestructive(isPresented:...)` for an item: shown while `item` is set, `action` gets the item,
    /// and the item is cleared on either button.
    func confirmDestructive<Item>(item: Binding<Item?>, title: String, message: ((Item) -> String)? = nil,
                                  actionTitle: String, action: @escaping (Item) -> Void) -> some View {
        let shown = Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        return confirmationDialog(Text(ui: title), isPresented: shown, titleVisibility: .visible,
                                  presenting: item.wrappedValue) { value in
            Button(role: .destructive) { action(value) } label: { Text(ui: actionTitle) }
            Button("Cancel", role: .cancel) {}
        } message: { value in
            if let message { Text(ui: message(value)) }
        }
    }
}

#Preview("Confirm destructive") {
    @Previewable @State var shown = true
    Button("Delete Flight") { shown = true }
        .confirmDestructive(isPresented: $shown, title: "Delete this flight from your Passport?",
                            message: "Its notes and seat go too. This can't be undone.",
                            actionTitle: "Delete Flight") {}
}
