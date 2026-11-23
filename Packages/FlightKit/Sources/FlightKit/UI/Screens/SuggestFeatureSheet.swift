import SwiftUI

/// Settings > Suggest a Feature: the idea, an optional email for a reply, and Send. Send waits for 3
/// characters other than spaces; the idea stops at 4000. A refusal keeps everything typed and says why
/// under the fields; once stored, a short thank-you shows and the sheet closes on its own.
struct SuggestFeatureSheet: View {
    var client = FeatureRequestClient()
    /// How long the thank-you stays before the sheet closes.
    var thanksDelay: Duration = .seconds(1.6)

    enum Field: Hashable { case message, email }

    @State private var message = ""
    @State private var email = ""
    @State private var sending = false
    @State private var sent = false
    @State private var failure: FeatureRequestClient.Failure?
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.metricsScale) private var scale

    static let title = "Suggest a Feature"
    static let thanks = "Thanks, we read every idea."

    var body: some View {
        VStack(spacing: 0) {
            SuggestFeatureHeader()
            if sent {
                thankYou
            } else {
                ScrollView { form }
                    .scrollDismissesKeyboard(.interactively)
            }
        }
        .background(Theme.background)
        .keyboardDoneBar()
        .guardsUnsavedChanges(isDirty: !sent && !FeatureRequestClient.trimmed(message).isEmpty, isSaving: sending)
        .onChange(of: message) { _, new in
            if new.count > FeatureRequestClient.maxLength { message = String(new.prefix(FeatureRequestClient.maxLength)) }
            if failure == .messageTooShort || failure == .messageTooLong { failure = nil }
        }
        .onChange(of: email) { if failure == .invalidEmail { failure = nil } }
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.metric(Theme.Space.md, scale)) {
            FormField("Your idea", text: $message, prompt: "What would make the app better for you?",
                      error: messageError, footnote: counter, submitLabel: .return, axis: .vertical, lines: 5...12,
                      focus: $focus, field: .message)
            FormField("Email (optional)", text: $email, prompt: "you@example.com",
                      error: failure == .invalidEmail ? failure?.message : nil,
                      footnote: "Only if you'd like a reply.", keyboard: .email, content: .email,
                      capitalization: .never, autocorrect: false, submitLabel: .send,
                      focus: $focus, field: .email, onSubmit: send)
            if let failure, !failure.isFieldError {
                Label { Text(ui: failure.message) } icon: { Image(systemName: "exclamationmark.circle.fill") }
                    .scaledFont(13, weight: .medium)
                    .foregroundStyle(Theme.veryLateText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: send) {
                Text("Send").frame(maxWidth: .infinity)
            }
            .loadingButton(isLoading: sending, variant: .filled)
            .disabled(!FeatureRequestClient.canSend(message))
            .accessibilityHint(FeatureRequestClient.canSend(message) ? Text(verbatim: "")
                               : Text("Write at least 3 characters."))
            .scaledPadding(.top, 4)
        }
        .scaledPadding(.horizontal, Theme.gutter)
        .scaledPadding(.vertical, Theme.Space.md)
    }

    private var thankYou: some View {
        VStack(spacing: Theme.metric(Theme.Space.sm, scale)) {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(44, weight: .semibold)
                .foregroundStyle(Theme.onTime)
                .accessibilityHidden(true)
            Text(ui: Self.thanks)
                .themeFont(.body)
                .foregroundStyle(Theme.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scaledPadding(.horizontal, Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var messageError: String? {
        guard let failure, failure == .messageTooShort || failure == .messageTooLong else { return nil }
        return failure.message
    }

    /// "12 of 4000", the notes editor's counter.
    private var counter: String {
        String(format: UIText.localized("%lld of %lld"), message.count, FeatureRequestClient.maxLength)
    }

    private func send() {
        guard !sending, FeatureRequestClient.canSend(message) else { return }
        focus = nil
        failure = nil
        sending = true
        let context = FeatureRequestClient.Context.current()
        Task {
            let result = await client.send(message: message, email: email, context: context)
            sending = false
            switch result {
            case .success:
                withAnimation(.easeOut(duration: 0.2)) { sent = true }
                announce(Self.thanks)
                try? await Task.sleep(for: thanksDelay)
                dismiss()
            case .failure(let f):
                failure = f
                announce(f.message)
            }
        }
    }

    private func announce(_ text: String) {
        #if os(iOS)
        AccessibilityNotification.Announcement(UIText.localized(text)).post()
        #endif
    }
}

extension FeatureRequestClient.Failure {
    /// Shown under its own field rather than above Send.
    var isFieldError: Bool { self == .messageTooShort || self == .messageTooLong || self == .invalidEmail }
}

/// The sheet's modal header (R5): Cancel on the left through `guardsUnsavedChanges`, which asks before an
/// idea typed is dropped.
private struct SuggestFeatureHeader: View {
    @Environment(\.requestCancel) private var requestCancel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetHeader(.modal(title: SuggestFeatureSheet.title,
                           leading: .cancel { if let requestCancel { requestCancel() } else { dismiss() } }))
            .scaledPadding(.top, 8)
    }
}

#if DEBUG
#Preview("Suggest a Feature") {
    SuggestFeatureSheet(client: FeatureRequestClient { request in
        try await Task.sleep(for: .seconds(1))
        let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
        return (Data(#"{"id":1}"#.utf8), response)
    })
}
#endif
