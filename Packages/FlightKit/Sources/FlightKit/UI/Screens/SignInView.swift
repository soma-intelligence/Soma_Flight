import AuthenticationServices
import MapKit
import SwiftUI

/// First screen without a session: the satellite globe behind, the app's icon and name, one line on what
/// the app does, Sign in with Apple, and an email link. Apple sign-in signs into `session` with a nonce; the email link comes back through
/// the app's URL handler (`SessionStore.handle(url:)`).
public struct SignInView: View {
    var session: SessionStore
    var onEmail: ((String) async -> Bool)?
    var onGoogle: (() async -> Void)?

    private enum EmailState: Equatable { case idle, sending, sent(String), failed }

    @State private var email = ""
    @State private var emailState: EmailState = .idle
    /// The nonce of the Apple request in flight: its hash goes in the request, the raw value to Supabase.
    @State private var nonce: AppleNonce?
    @State private var appleFailed = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.airportStaticControls) private var staticControls
    @ScaledMetric(relativeTo: .body) private var logo = 92
    /// The height of every control in the form, as Apple's own sign-in sheets use.
    @ScaledMetric(relativeTo: .body) private var controlHeight: CGFloat = 54

    /// - Parameters:
    ///   - onEmail: sends a sign-in link to the (trimmed) address and returns whether it went out. The
    ///     button is disabled while it runs, and nil disables the email path.
    ///   - onGoogle: Google sign-in; nil hides the button (it stays hidden until the owner turns Google on).
    public init(session: SessionStore, onEmail: ((String) async -> Bool)? = nil, onGoogle: (() async -> Void)? = nil) {
        self.session = session; self.onEmail = onEmail; self.onGoogle = onGoogle
    }

    private var trimmed: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var emailLooksValid: Bool { Self.isValid(email) }

    /// Whitespace around the address (autofill often adds a trailing space) does not make it invalid.
    static func isValid(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]+/) != nil
    }

    private var canSend: Bool { emailLooksValid && onEmail != nil && emailState != .sending }

    public var body: some View {
        // One stable layout: a scroll view whose content is at least as tall as the screen, so the form sits
        // low with the intro above it. Large text or the keyboard make it scroll. The view tree never
        // changes with the available height, so the email field keeps focus when the keyboard rises.
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)
                    intro
                    Spacer(minLength: 40)
                    form
                }
                .frame(minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .background { backdrop }
    }

    /// The home's satellite globe, turning slowly, fading into the page below the intro so the form sits on plain
    /// dark. Snapshots get the plain page (ImageRenderer cannot draw a map).
    @ViewBuilder private var backdrop: some View {
        if staticControls {
            Theme.background.ignoresSafeArea()
        } else {
            ZStack {
                Color.black
                SpinningGlobe()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                LinearGradient(stops: [.init(color: .black.opacity(0.15), location: 0),
                                       .init(color: .black.opacity(0.55), location: 0.35),
                                       .init(color: Theme.background, location: 0.62)],
                               startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
        }
    }

    private var intro: some View {
        VStack(spacing: 14) {
            Self.appIcon
                .resizable()
                .interpolation(.high)
                .frame(width: logo, height: logo)
                .clipShape(RoundedRectangle(cornerRadius: logo * 0.225, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
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
        .scaledPadding(.horizontal, 28)
    }

    /// The app's own icon (Resources/brand-app-icon.png, from assets/icon), so the first screen shows the
    /// mark the Home Screen does.
    static var appIcon: Image {
        #if os(iOS)
        if let url = Bundle.module.url(forResource: "brand-app-icon", withExtension: "png"),
           let image = UIImage(contentsOfFile: url.path) { return Image(uiImage: image) }
        #else
        if let url = Bundle.module.url(forResource: "brand-app-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) { return Image(nsImage: image) }
        #endif
        return Image(systemName: "globe.americas.fill")
    }

    private var form: some View {
        VStack(spacing: 12) {
            if let error = session.error {
                ErrorBanner(error: error)
            }
            appleButton
            if let onGoogle {
                Button { Task { await onGoogle() } } label: {
                    Label("Continue with Google", systemImage: "g.circle.fill")
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(Theme.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: controlHeight)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.pill))
                }
                .buttonStyle(.plain)
            }
            if appleFailed {
                Text("Sign in with Apple didn't work. You can use your email instead.")
                    .scaledFont(13)
                    .foregroundStyle(Theme.veryLate)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("or")
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .scaledPadding(.vertical, 2)
            if case .sent(let address) = emailState {
                sentNotice(address)
            } else {
                emailForm
            }
            Text("We only use your email to sign you in.")
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .scaledPadding(.top, 4)
        }
        .scaledPadding(.horizontal, 20)
        .scaledPadding(.bottom, 28)
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
            .scaledPadding(.horizontal, 14)
            .scaledPadding(.vertical, 4)
            .frame(height: controlHeight)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.pill))
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
            .frame(height: controlHeight)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
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
                .scaledPadding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .scaledPadding(.all, 16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.pill))
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

    /// Hands Apple's identity token and the raw nonce to the session. Cancelling is not a failure.
    private func completeApple(_ result: Result<ASAuthorization, any Error>) {
        let raw = nonce?.raw
        nonce = nil
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let token = String(data: data, encoding: .utf8), let raw else {
                appleFailed = true
                return
            }
            appleFailed = false
            // Apple's name comes only on the very first authorization: hand it over now or lose it.
            let name = credential.fullName
            Task { await session.signInWithApple(idToken: token, nonce: raw, fullName: name) }
        case .failure(let error):
            appleFailed = (error as? ASAuthorizationError)?.code != .canceled
        }
    }

    @ViewBuilder private var appleButton: some View {
        if staticControls {
            // ImageRenderer cannot draw the system button; snapshots get a plain stand-in.
            Label("Sign in with Apple", systemImage: "apple.logo")
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(scheme == .dark ? Color.black : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: controlHeight)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(scheme == .dark ? Color.white : Color.black))
        } else {
            SignInWithAppleButton(.signIn) { request in
                let fresh = AppleNonce.random()
                nonce = fresh
                request.requestedScopes = [.fullName, .email]
                request.nonce = fresh.hashed
            } onCompletion: { result in
                completeApple(result)
            }
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            // A fixed height: given only a minimum, the system button grows to fill the free space.
            .frame(height: controlHeight)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// The satellite globe turning eastward at about a third of a degree a second (one turn in 18 minutes),
/// still when Reduce Motion is on. The camera moves in small steps, and the loop stops with the view.
struct SpinningGlobe: View {
    /// Degrees of longitude per second.
    static let speed = 0.33
    static let latitude = 34.0
    static let distance = 24_000_000.0
    @State private var longitude = -40.0
    @State private var position: MapCameraPosition = .camera(SpinningGlobe.camera(longitude: -40))
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func camera(longitude: Double) -> MapCamera {
        MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                  distance: distance, heading: 0, pitch: 0)
    }

    /// Longitude kept in -180...180 as it grows.
    static func advanced(_ longitude: Double, by seconds: Double) -> Double {
        var l = longitude + speed * seconds
        if l > 180 { l -= 360 }
        return l
    }

    var body: some View {
        Map(position: $position, interactionModes: [])
            .mapStyle(.imagery(elevation: .realistic))
            .mapControlVisibility(.hidden)
            .task(id: reduceMotion) {
                guard !reduceMotion else { return }
                var last = Date.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    let now = Date.now
                    longitude = Self.advanced(longitude, by: now.timeIntervalSince(last))
                    last = now
                    position = .camera(Self.camera(longitude: longitude))
                }
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
