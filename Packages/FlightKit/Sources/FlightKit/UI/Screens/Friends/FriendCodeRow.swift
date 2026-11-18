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

/// The user's friend code as one flat card (R6, R8): `FriendCodeLabel`, then Copy (a check for a moment once
/// copied), QR and Share, which makes the invitation link when tapped, each a 44 pt glass circle. The tab's
/// quieter actions (add a friend by code, pause every share, a new code, refresh) sit in the trailing menu and
/// on a long press of the card.
struct FriendCodeRow: View {
    var store: FriendsStore
    var onShowQR: () -> Void
    /// Opens Add a Friend (the header's old add button); nil leaves it out of the menu.
    var onAdd: (() -> Void)?
    @State private var copied = false
    @State private var resetCopied: Task<Void, Never>?
    @Environment(\.metricsScale) private var scale
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let code = store.me?.friendCode
        RefinedCard(padding: 0) {
            Group {
                // At accessibility sizes the code takes the card's full width over the buttons, so it stays
                // whole and readable (A12).
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: Theme.metric(Theme.Space.sm, scale)) {
                        label(code)
                        HStack(spacing: Theme.metric(Theme.Space.xs, scale)) { buttons(code) }
                    }
                } else {
                    HStack(spacing: Theme.metric(8, scale)) {
                        label(code)
                        Spacer(minLength: 4)
                        buttons(code)
                    }
                }
            }
            .scaledPadding(.leading, 16)
            .scaledPadding(.trailing, 4)
            .scaledPadding(.vertical, 16)
        }
        .contentShape(Rectangle())
        .contextMenu { options }
        .onDisappear { resetCopied?.cancel(); resetCopied = nil }
    }

    private func label(_ code: String?) -> some View {
        FriendCodeLabel(code: code)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(code.map { "Your friend code, \(FriendFacts.spokenCode($0))" } ?? "Your friend code")
    }

    @ViewBuilder private func buttons(_ code: String?) -> some View {
        icon(copied ? "checkmark" : "doc.on.doc", label: copied ? "Copied" : "Copy Friend Code",
             tint: copied ? Theme.onTime : Theme.primary, action: copy)
            .disabled(code == nil)
        icon("qrcode", label: "Show QR Code", action: onShowQR)
            .disabled(code == nil)
        InviteShareButton(store: store) { circle("square.and.arrow.up", tint: Theme.primary) }
            .buttonStyle(.plain)
            .accessibilityLabel("Share Invitation")
        menu
    }

    @ViewBuilder private var options: some View {
        if let onAdd {
            Button("Add a Friend", systemImage: "person.badge.plus", action: onAdd)
        }
        if let me = store.me {
            Button("Show QR Code", systemImage: "qrcode", action: onShowQR)
            Divider()
            Toggle("Pause All Sharing", systemImage: "pause.circle",
                   isOn: Binding(get: { me.sharingPaused }, set: { v in Task { await store.setPaused(v) } }))
            Button("New Friend Code", systemImage: "arrow.triangle.2.circlepath") { Task { await store.resetCode() } }
        }
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.load() } }
    }

    private var menu: some View {
        Menu { options } label: {
            Image(systemName: "ellipsis")
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.secondary)
                .frame(width: Theme.metric(44, scale), height: Theme.metric(44, scale))
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Friend Code Options")
    }

    private func icon(_ systemImage: String, label: String, tint: Color = Theme.primary,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) { circle(systemImage, tint: tint) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    /// A 44 pt glass circle, the card's one button shape (R9 tap target).
    private func circle(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .scaledFont(17, weight: .semibold)
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: Theme.metric(44, scale), height: Theme.metric(44, scale))
            .contentShape(Circle())
            .roundGlass()
    }

    private func copy() {
        guard let code = store.me?.friendCode else { return }
        Pasteboard.copy(code, sensitive: true)
        withAnimation(.snappy) { copied = true }
        resetCopied?.cancel()
        resetCopied = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { copied = false }
        }
    }
}

// MARK: - Code label

/// The card's label: a small caps "YOUR CODE" in secondary over the code in SF Pro Rounded, its two groups
/// of four split by a centred dot. Codes use Crockford's alphabet (no I, L, O or U), so a rounded face stays
/// unambiguous. VoiceOver reads the card's own label, one character at a time.
struct FriendCodeLabel: View {
    var code: String?
    @Environment(\.metricsScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.metric(4, scale)) {
            Text("YOUR CODE")
                .scaledFont(12, weight: .medium, relativeTo: .caption)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            // The two groups side by side, or one over the other when a large text size leaves no room: never
            // "K7..." (A12).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.metric(8, scale)) {
                    first
                    Circle()
                        .fill(Theme.primary)
                        .frame(width: Theme.metric(4, scale), height: Theme.metric(4, scale))
                    second
                }
                VStack(alignment: .leading, spacing: 0) {
                    first
                    second
                }
            }
        }
    }

    private var first: some View { group(code?.count == 8 ? code.map { String($0.prefix(4)) } : nil) }
    private var second: some View { group(code?.count == 8 ? code.map { String($0.suffix(4)) } : nil) }

    private func group(_ text: String?) -> some View {
        Text(text ?? "····")
            .scaledFont(22, weight: .semibold, design: .rounded)
            .monospacedDigit()
            .tracking(1.5)
            .foregroundStyle(Theme.primary)
            .fixedSize()
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
            Text(ui: blurb)
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
                Text(ui: me.spacedCode)
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
