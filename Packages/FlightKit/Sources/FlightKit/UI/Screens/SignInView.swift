import AuthenticationServices
import SwiftUI

/// First screen without a session: the name, one line on what the app does, Sign in with Apple,
/// and an email link. The Apple and email flows are wired in Task 9.
public struct SignInView: View {
    var session: SessionStore
    var onApple: ((Result<ASAuthorization, any Error>) -> Void)?
    var onEmail: ((String) -> Void)?

    @State private var email = ""
    @Environment(\.colorScheme) private var scheme
    @Environment(\.airportStaticControls) private var staticControls

    /// - Parameters:
    ///   - onApple: the Apple authorization result (Task 9 turns it into a session).
    ///   - onEmail: sends a sign-in link to the address.
    public init(session: SessionStore, onApple: ((Result<ASAuthorization, any Error>) -> Void)? = nil,
                onEmail: ((String) -> Void)? = nil) {
        self.session = session; self.onApple = onApple; self.onEmail = onEmail
    }

    private var emailLooksValid: Bool {
        email.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]+/) != nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            VStack(spacing: 14) {
                Image(systemName: "airplane")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .frame(width: 68, height: 68)
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
            Spacer(minLength: 40)

            VStack(spacing: 12) {
                if let error = session.error {
                    ErrorBanner(error: error)
                }
                appleButton
                Text("or")
                    .scaledFont(13)
                    .foregroundStyle(Theme.secondary)
                    .padding(.vertical, 2)
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
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.pill))
                    .onSubmit(sendEmail)
                Button(action: sendEmail) {
                    Text("Email Me a Sign-In Link")
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(emailLooksValid ? Color.white : Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(emailLooksValid ? Theme.accent : Theme.pill))
                }
                .buttonStyle(.plain)
                .disabled(!emailLooksValid)
                Text("We only use your email to sign you in.")
                    .scaledFont(13)
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
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
        guard emailLooksValid else { return }
        onEmail?(email.trimmingCharacters(in: .whitespaces))
    }

    @ViewBuilder private var appleButton: some View {
        if staticControls {
            // ImageRenderer cannot draw the system button; snapshots get a plain stand-in.
            Label("Sign in with Apple", systemImage: "apple.logo")
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(scheme == .dark ? Color.black : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(scheme == .dark ? Color.white : Color.black))
        } else {
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email]
            } onCompletion: { result in
                onApple?(result)
            }
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// MARK: - Previews

struct SignInPreview: View {
    var failed = false
    @State private var session: SessionStore?

    var body: some View {
        Group {
            if let session { SignInView(session: session) } else { ProgressView() }
        }
        .task {
            let auth = FakeAuthService()
            let s = SessionStore(auth: auth)
            if failed {
                await auth.setNextError(.providerUnavailable)
                await s.deleteAccount()
            }
            session = s
        }
    }
}

#Preview("Dark") { SignInPreview().preferredColorScheme(.dark) }
#Preview("Light") { SignInPreview().preferredColorScheme(.light) }
#Preview("Error") { SignInPreview(failed: true).preferredColorScheme(.dark) }
