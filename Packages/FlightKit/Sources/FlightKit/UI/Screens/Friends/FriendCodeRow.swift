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

// MARK: - Code row

/// The user's friend code as one slim row at the top of the tab: `FriendCodeLabel`, then QR, Copy (a
/// check for a moment once copied) and Share, which makes the invitation link when tapped. The tab's quieter actions (pause every share, a new code, refresh) sit in the trailing
/// menu and on a long press of the row.
struct FriendCodeRow: View {
    var store: FriendsStore
    var onShowQR: () -> Void
    @State private var copied = false
    @State private var resetCopied: Task<Void, Never>?
    @Environment(\.metricsScale) private var scale

    var body: some View {
        let code = store.me?.friendCode
        HStack(spacing: Theme.metric(8, scale)) {
            FriendCodeLabel(code: code)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(code.map { "Your friend code, \(FriendFacts.spokenCode($0))" } ?? "Your friend code")
            Spacer(minLength: 4)
            icon("qrcode", label: "Show QR Code", action: onShowQR)
                .disabled(code == nil)
            icon(copied ? "checkmark" : "doc.on.doc", label: copied ? "Copied" : "Copy Friend Code",
                 tint: copied ? Theme.onTime : Theme.primary, action: copy)
                .disabled(code == nil)
            InviteShareButton(store: store) { circle("square.and.arrow.up", tint: Theme.primary) }
                .buttonStyle(.plain)
                .accessibilityLabel("Share Invitation")
            menu
        }
        .scaledPadding(.leading, 16)
        .scaledPadding(.trailing, 6)
        .frame(height: Theme.metric(54, scale))
        .background(Capsule().fill(Theme.card.opacity(0.5)))
        .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
        .contentShape(Capsule())
        .contextMenu { options }
        .onDisappear { resetCopied?.cancel(); resetCopied = nil }
    }

    @ViewBuilder private var options: some View {
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
                .frame(width: Theme.metric(28, scale), height: Theme.metric(40, scale))
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

    private func circle(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .scaledFont(14, weight: .semibold)
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: Theme.metric(36, scale), height: Theme.metric(36, scale))
            .background(Circle().fill(Theme.pill))
            .contentShape(Circle())
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

/// The row's label: a small tracked "YOUR CODE" over the code in SF Pro Rounded, its two groups of four
/// split by a centred dot. Codes use Crockford's alphabet (no I, L, O or U), so a rounded face stays
/// unambiguous. VoiceOver reads the row's own label, one character at a time.
struct FriendCodeLabel: View {
    var code: String?
    @Environment(\.metricsScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.metric(3, scale)) {
            Text("YOUR CODE")
                .scaledFont(10, weight: .semibold, relativeTo: .caption2)
                .tracking(1.4)
                .foregroundStyle(Theme.secondary.opacity(0.8))
                .lineLimit(1)
            HStack(spacing: Theme.metric(7, scale)) {
                group(code?.count == 8 ? code.map { String($0.prefix(4)) } : nil)
                Circle()
                    .fill(Theme.secondary.opacity(0.6))
                    .frame(width: Theme.metric(3.5, scale), height: Theme.metric(3.5, scale))
                group(code?.count == 8 ? code.map { String($0.suffix(4)) } : nil)
            }
        }
    }

    private func group(_ text: String?) -> some View {
        Text(text ?? "····")
            .scaledFont(19, weight: .medium, design: .rounded)
            .monospacedDigit()
            .tracking(1.8)
            .foregroundStyle(Theme.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
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
