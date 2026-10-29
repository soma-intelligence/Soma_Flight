import AuthenticationServices
import SwiftUI

/// First screen without a session: the name, one line on what the app does, Sign in with Apple,
/// and an email link. The Apple and email flows are wired in Task 9.
public struct SignInView: View {
    var session: SessionStore
    var onApple: ((Result<ASAuthorization, any Error>) -> Void)?
    var onEmail: ((String) async -> Bool)?

    private enum EmailState: Equatable { case idle, sending, sent(String), failed }

    @State private var email = ""
    @State private var emailState: EmailState = .idle
    @Environment(\.colorScheme) private var scheme
    @Environment(\.airportStaticControls) private var staticControls
    @ScaledMetric(relativeTo: .body) private var logo = 68

    /// - Parameters:
    ///   - onApple: the Apple authorization result (Task 9 turns it into a session).
    ///   - onEmail: sends a sign-in link to the (trimmed) address and returns whether it went out. The
    ///     button is disabled while it runs, and nil disables the email path.
    public init(session: SessionStore, onApple: ((Result<ASAuthorization, any Error>) -> Void)? = nil,
                onEmail: ((String) async -> Bool)? = nil) {
        self.session = session; self.onApple = onApple; self.onEmail = onEmail
    }

    private var trimmed: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var emailLooksValid: Bool { Self.isValid(email) }

    /// Whitespace around the address (autofill often adds a trailing space) does not make it invalid.
    static func isValid(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]+/) != nil
    }

    private var canSend: Bool { emailLooksValid && onEmail != nil && emailState != .sending }

    public var body: some View {
        // Fits on one screen: the form sits low with the intro above it. Past that (large text, keyboard
        // up) the same content scrolls.
        ViewThatFits(in: .vertical) {
            layout(spacers: true)
            ScrollView { layout(spacers: false) }.scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }

    private func layout(spacers: Bool) -> some View {
        VStack(spacing: 0) {
            if spacers { Spacer(minLength: 40) } else { Color.clear.frame(height: 40) }
            intro
            if spacers { Spacer(minLength: 40) } else { Color.clear.frame(height: 40) }
            form
        }
    }

    private var intro: some View {
        VStack(spacing: 14) {
            Image(systemName: "airplane")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .frame(width: logo, height: logo)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
                .accessibilityHidden(true)
            Text("Soma Flight")
                .scaledFont(34, weight: .bold, relativeTo: .largeTitle)
                .foregroundStyle(Theme.primary)
            Text("Live status for the flights you follow, delays explained, and a record of everywhere you've flown.")
                .scaledFont(17)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
    }

    private var form: some View {
        VStack(spacing: 12) {
            if let error = session.error {
                ErrorBanner(error: error)
            }
            appleButton
            Text("or")
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .padding(.vertical, 2)
            if case .sent(let address) = emailState {
                sentNotice(address)
            } else {
                emailForm
            }
            Text("We only use your email to sign you in.")
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
    }

    @ViewBuilder private var emailForm: some View {
        emailField
            .scaledFont(17)
            .textFieldStyle(.plain)
            .textContentType(.emailAddress)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            #endif
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.pill))
            .onSubmit(sendEmail)
        if emailState == .failed {
            Text("The link didn't go out. Check the address and try again.")
                .scaledFont(13)
                .foregroundStyle(Theme.veryLate)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        Button(action: sendEmail) {
            Group {
                if emailState == .sending {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Email Me a Sign-In Link").scaledFont(17, weight: .semibold)
                }
            }
            .foregroundStyle(canSend || emailState == .sending ? Color.white : Theme.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .frame(minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(canSend || emailState == .sending ? Theme.accent : Theme.pill))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
    }

    private func sentNotice(_ address: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope.badge")
                .scaledFont(24, weight: .semibold)
                .foregroundStyle(Theme.onTime)
                .accessibilityHidden(true)
            Text("Check your email")
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(Theme.primary)
            Text("We sent a sign-in link to \(address). Open it on this device.")
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Use a different email") { emailState = .idle }
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.pill))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var emailField: some View {
        if staticControls {
            Text("Email address")
                .foregroundStyle(Theme.secondary.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("", text: $email, prompt: Text("Email address").foregroundStyle(Theme.secondary.opacity(0.75)))
        }
    }

    private func sendEmail() {
        guard canSend, let onEmail else { return }
        let address = trimmed
        emailState = .sending
        Task {
            let ok = await onEmail(address)
            emailState = ok ? .sent(address) : .failed
        }
    }

    @ViewBuilder private var appleButton: some View {
        if staticControls {
            // ImageRenderer cannot draw the system button; snapshots get a plain stand-in.
            Label("Sign in with Apple", systemImage: "apple.logo")
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(scheme == .dark ? Color.black : Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .frame(minHeight: 50)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(scheme == .dark ? Color.white : Color.black))
        } else {
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email]
            } onCompletion: { result in
                onApple?(result)
            }
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .frame(minHeight: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

#if DEBUG
// MARK: - Previews

struct SignInPreview: View {
    var failed = false
    @State private var session: SessionStore?

    var body: some View {
        Group {
            if let session { SignInView(session: session, onEmail: { _ in true }) } else { ProgressView() }
        }
        .task {
            let s = SessionStore(auth: FakeAuthService())
            s.seed(error: failed ? .providerUnavailable : nil)
            session = s
        }
    }
}

#Preview("Dark") { SignInPreview().preferredColorScheme(.dark) }
#Preview("Light") { SignInPreview().preferredColorScheme(.light) }
#Preview("Error") { SignInPreview(failed: true).preferredColorScheme(.dark) }
#endif
