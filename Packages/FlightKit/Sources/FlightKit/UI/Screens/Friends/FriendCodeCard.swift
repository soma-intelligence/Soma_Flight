import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - QR code

/// Draws a QR code with CoreImage, for a phone camera to open.
enum FriendQR {
    /// The QR code of `text`, each module `scale` pixels wide, black on white; nil if CoreImage fails.
    static func image(_ text: String, scale: CGFloat = 12) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(out, from: out.extent)
    }
}

// MARK: - Code card

/// The user's friend code as a card: the code large, Copy and Share, a quiet caption, and a menu with the
/// tab's other actions (pause every share, a new code, refresh). Tapping the code shows it as a QR code.
struct FriendCodeCard: View {
    var store: FriendsStore
    var onShowQR: () -> Void
    @State private var copied = false
    @State private var resetCopied: Task<Void, Never>?

    var body: some View {
        let code = store.me?.friendCode
        DetailCard {
            HStack(alignment: .center) {
                Text("Your Friend Code").scaledFont(15, weight: .semibold).foregroundStyle(Theme.secondary)
                Spacer(minLength: 8)
                menu
            }
            Button(action: onShowQR) {
                HStack(alignment: .center, spacing: 12) {
                    Text(store.me?.spacedCode ?? FriendFacts.codePlaceholder)
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.primary)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "qrcode")
                        .scaledFont(22, weight: .medium)
                        .foregroundStyle(Theme.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(code == nil)
            .accessibilityLabel(code.map { "Your friend code, \(FriendFacts.spokenCode($0))" } ?? "Your friend code")
            .accessibilityHint("Shows it as a QR code")
            .scaledPadding(.top, 6)

            HStack(spacing: 10) {
                Button { copy() } label: {
                    pill(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(code == nil)
                InviteShareButton(store: store) {
                    pill("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
            .scaledPadding(.top, 14)

            Text("Friends add you with it, and you accept each request. Tap the code to show a QR code.")
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 12)
        }
        .onDisappear { resetCopied?.cancel(); resetCopied = nil }
    }

    private var menu: some View {
        Menu {
            if let me = store.me {
                Toggle("Pause All Sharing", systemImage: "pause.circle",
                       isOn: Binding(get: { me.sharingPaused }, set: { v in Task { await store.setPaused(v) } }))
                Button("New Friend Code", systemImage: "arrow.triangle.2.circlepath") { Task { await store.resetCode() } }
            }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.load() } }
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(Theme.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Friend Code Options")
    }

    private func pill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .scaledFont(15, weight: .semibold)
            .foregroundStyle(Theme.primary)
            .frame(maxWidth: .infinity)
            .scaledPadding(.vertical, 10)
            .background(Capsule().fill(Theme.pill))
            .contentShape(Capsule())
    }

    private func copy() {
        guard let code = store.me?.friendCode else { return }
        Pasteboard.copy(code, sensitive: true)
        copied = true
        resetCopied?.cancel()
        resetCopied = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

// MARK: - QR sheet

/// The friend code's QR sheet: a new invitation link as a QR code another phone's camera opens (the same
/// invitation the share sheet sends), with the code under it to read out instead.
struct FriendQRSheet: View {
    var store: FriendsStore
    var onClose: () -> Void
    @State private var url: URL?
    @State private var failure: APIError?
    @State private var making: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack { Spacer(); RoundButton(systemImage: "xmark", label: "Close", action: onClose) }
            Text("Scan to Be Friends")
                .scaledFont(24, weight: .bold)
                .foregroundStyle(Theme.primary)
                .scaledPadding(.top, 4)
            Text(blurb)
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 6)
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white)
                if let url, let image = FriendQR.image(url.absoluteString) {
                    Image(image, scale: 1, label: Text("QR code of your invitation"))
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .scaledPadding(.all, 20)
                } else if failure == nil {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 34)).foregroundStyle(.gray)
                        .accessibilityLabel("The invitation could not be made")
                }
            }
            .frame(width: 260, height: 260)
            .scaledPadding(.top, 24)
            if let failure { ErrorBanner(error: failure, retry: make).scaledPadding(.top, 14) }
            if let me = store.me {
                Text(me.spacedCode)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.primary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Your friend code, \(FriendFacts.spokenCode(me.friendCode))")
                    .scaledPadding(.top, 20)
            }
            Spacer(minLength: 0)
        }
        .scaledPadding(.horizontal, 24)
        .scaledPadding(.top, 16)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        .presentationCornerRadius(Theme.sheetRadius)
        .task { if url == nil { make() } }
        .onDisappear { making?.cancel(); making = nil }
    }

    /// What the sheet says about the invitation, with its end taken from the invitation itself.
    private var blurb: String {
        FriendFacts.qrBlurb(expiresAt: store.invite?.expiresAt, now: .now)
    }

    private func make() {
        guard making == nil else { return }
        failure = nil
        making = Task {
            defer { making = nil }
            do throws(APIError) { url = try await store.shareInviteURL() } catch {
                if !Task.isCancelled { failure = error }
            }
        }
    }
}
