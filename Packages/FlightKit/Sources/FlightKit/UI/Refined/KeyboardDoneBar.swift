import SwiftUI

// Contract
// - Name: `.keyboardDoneBar(_:)` (I12).
// - Use: once per editor screen or sheet that has a number pad, a phone pad or a multi-line field (keyboards
//   with no Return key). Put it on the form, not on each field.
// - Variants: an optional action run before the keyboard closes (commit the field).
// - States: shown with the keyboard only.
// - Tokens: the system keyboard toolbar.
// - A11y: a "Done" button, a catalog key.
// - Reduce Motion: system.
// - Previews: below.

public extension View {
    /// A keyboard toolbar with a trailing Done that ends editing. iOS only; a no-op on the Mac.
    func keyboardDoneBar(_ onDone: (() -> Void)? = nil) -> some View {
        #if os(iOS)
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    onDone?()
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil,
                                                    for: nil)
                }
                .fontWeight(.semibold)
            }
        }
        #else
        self
        #endif
    }
}

#Preview("Keyboard Done bar") {
    @Previewable @State var minutes = "45"
    NavigationStack {
        Form {
            TextField("Minutes", text: $minutes)
        }
        .keyboardDoneBar()
    }
}
