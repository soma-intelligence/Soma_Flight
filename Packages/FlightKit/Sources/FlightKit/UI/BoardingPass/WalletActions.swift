import SwiftUI
#if os(iOS)
import PassKit
#endif

/// Add to Apple Wallet, or Open in Wallet once the pass is there, for a pass that came from a Wallet file.
///
/// What PassKit lets a third-party app do with an airline's pass: it cannot list or read the passes in
/// Wallet (`PKPassLibrary.passes()` only returns passes whose pass type identifiers the app's own
/// entitlement names, and those belong to the airline's team), so the app cannot find a pass the traveller
/// added from the airline's app. It can do three things with the signed file it holds: show the system's
/// add sheet (`PKAddPassesViewController`, from the official `PKAddPassButton`), ask whether Wallet already
/// has that pass (`PKPassLibrary.containsPass(_:)`, which Apple documents as working without access to
/// the pass), and open it in Wallet (`PKPass.passURL`). A scanned barcode has no signed file, so it shows
/// none of this. iOS only: the Mac has no Wallet app.
struct WalletActions: View {
    var store: FlightDetailStore

    var body: some View {
        #if os(iOS)
        WalletActionsPhone(store: store)
        #else
        EmptyView()
        #endif
    }
}

#if os(iOS)
private struct WalletActionsPhone: View {
    var store: FlightDetailStore
    @State private var pkpass: PKPass?
    @State private var inWallet = false
    @State private var adding = false
    @State private var checked = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if store.simulatesWallet || (pkpass != nil && PKAddPassesViewController.canAddPasses()) {
                if inWallet {
                    Button {
                        if let url = pkpass?.passURL { openURL(url) }
                    } label: {
                        Label("Open in Wallet", systemImage: "wallet.pass")
                            .scaledFont(17, weight: .semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Theme.pill)
                    .foregroundStyle(Theme.primary)
                } else {
                    AddPassButton { add() }
                        .frame(height: 50)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .task { await refresh() }
        .sheet(isPresented: $adding, onDismiss: { Task { await refresh() } }) {
            if let pkpass { AddPassesSheet(pass: pkpass) }
        }
    }

    private func add() {
        if store.simulatesWallet {
            // The fakes have no signed pass: the button only shows what happens after the system sheet.
            withAnimation { inWallet = true }
        } else if pkpass != nil {
            adding = true
        }
    }

    private func refresh() async {
        if store.simulatesWallet { return }
        if pkpass == nil, let file = await store.walletFile() {
            // Throws for a file whose signature does not check out; such a pass cannot go in Wallet.
            pkpass = try? PKPass(data: file)
        }
        if let pkpass { inWallet = PKPassLibrary().containsPass(pkpass) }
    }
}

/// The official Add to Apple Wallet button.
private struct AddPassButton: UIViewRepresentable {
    var action: () -> Void

    func makeUIView(context: Context) -> PKAddPassButton {
        let button = PKAddPassButton(addPassButtonStyle: .black)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: PKAddPassButton, context: Context) { context.coordinator.action = action }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tap() { action() }
    }
}

/// The system sheet that shows the pass and adds it to Wallet.
private struct AddPassesSheet: UIViewControllerRepresentable {
    var pass: PKPass

    func makeUIViewController(context: Context) -> UIViewController {
        PKAddPassesViewController(pass: pass) ?? UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
#endif

// MARK: - Brightness

extension View {
    /// Turns the screen to full brightness while this view shows, for a gate scanner, and puts it back
    /// when it goes or the app leaves the foreground. Nothing on the Mac.
    func fullBrightness() -> some View {
        #if os(iOS)
        modifier(FullBrightness())
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct FullBrightness: ViewModifier {
    @State private var saved: CGFloat?
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .onAppear(perform: raise)
            .onDisappear(perform: restore)
            .onChange(of: phase) { _, now in now == .active ? raise() : restore() }
    }

    private var screen: UIScreen? {
        // Any of the app's scenes: on the way to the background none is active any more.
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    private func raise() {
        guard let screen, saved == nil else { return }
        saved = screen.brightness
        screen.brightness = 1
    }

    private func restore() {
        guard let screen, let level = saved else { return }
        screen.brightness = level
        saved = nil
    }
}
#endif
