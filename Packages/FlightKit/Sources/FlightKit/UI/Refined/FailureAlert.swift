import SwiftUI

// Contract
// - Name: `.failureAlert(_:title:retry:)` (I6).
// - Use: an action that failed and has nothing on screen to show it (a share link, a save, a sign-out):
//   replaces the "OK only" alerts. A load that failed shows an `ErrorBanner` instead.
// - Variants: an `APIError?` binding (copy from `message(hasContent: false)`) or a `String?` binding (a
//   message the caller already wrote); `retry` nil leaves only OK.
// - States: shown while the binding is set; both buttons clear it, Try Again then runs `retry`.
// - Tokens: none (system alert).
// - A11y: the title and message are catalog keys; "Try Again" is the default action.
// - Reduce Motion: system.
// - Previews: below.

public extension View {
    /// An alert for a failed action: `title`, the error's copy, "Try Again" (runs `retry`) and "Cancel". With
    /// no `retry`, a single OK.
    func failureAlert(_ error: Binding<APIError?>, title: String = "Couldn't finish that",
                      retry: (() -> Void)? = nil) -> some View {
        failureAlert(Binding(get: { error.wrappedValue?.message(hasContent: false) },
                             set: { if $0 == nil { error.wrappedValue = nil } }),
                     title: title, retry: retry)
    }

    /// `failureAlert` with a message the caller already wrote.
    func failureAlert(_ message: Binding<String?>, title: String = "Couldn't finish that",
                      retry: (() -> Void)? = nil) -> some View {
        let shown = Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })
        return alert(Text(ui: title), isPresented: shown, presenting: message.wrappedValue) { _ in
            if let retry {
                Button("Try Again") { retry() }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { text in
            Text(ui: text)
        }
    }
}

#Preview("Failure alert") {
    @Previewable @State var error: APIError? = .offline
    Button("Share") { error = .offline }
        .failureAlert($error, retry: {})
}
