import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// What Invite a Friend and the code card's Share hand to the share sheet: the invitation in words (with the
/// friend code) and its link.
enum FriendInviteShare {
    /// The title the share sheet shows.
    static let title = "Soma Flight invitation"

    /// The items to share: the words, then the link; the words alone when no link could be made.
    static func items(text: String, link: URL?) -> [Any] {
        guard let link else { return [text] }
        return [text, link]
    }
}

/// A button that makes the invitation link once, when it is tapped (the store reuses the current invitation
/// until it nears its end), then opens the system share sheet with the link ready. Picking a receiver or
/// cancelling the sheet makes nothing more.
struct InviteShareButton<Label: View>: View {
    var store: FriendsStore
    @ViewBuilder var label: () -> Label
    @State private var making: Task<Void, Never>?
    #if os(iOS)
    @State private var sheet: ShareSheetItems?
    #else
    @State private var anchor = ShareAnchor.Holder()
    #endif

    var body: some View {
        Button(action: tap) { label().opacity(making == nil ? 1 : 0.55) }
            .disabled(making != nil || store.me?.friendCode == nil)
            .accessibilityHint("Opens the share sheet with a single-use invitation link")
            #if os(iOS)
            .sheet(item: $sheet) { items in
                ActivityView(items: items.values)
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
            #else
            .background(ShareAnchor(holder: anchor))
            #endif
            .onDisappear { making?.cancel(); making = nil }
    }

    private func tap() {
        guard making == nil else { return }
        let text = FriendFacts.inviteMessage(code: store.me?.friendCode)
        making = Task {
            var link: URL?
            do throws(APIError) { link = try await store.shareInviteURL() } catch { link = nil }
            guard !Task.isCancelled else { return }
            making = nil
            present(FriendInviteShare.items(text: text, link: link))
        }
    }

    private func present(_ items: [Any]) {
        #if os(iOS)
        sheet = ShareSheetItems(values: items)
        #else
        anchor.show(items)
        #endif
    }
}

#if os(iOS)
struct ShareSheetItems: Identifiable {
    let id = UUID()
    var values: [Any]
}

/// `UIActivityViewController` for SwiftUI.
struct ActivityView: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
/// An invisible view the Mac's share picker hangs from.
struct ShareAnchor: NSViewRepresentable {
    @MainActor final class Holder {
        weak var view: NSView?
        func show(_ items: [Any]) {
            guard let view else { return }
            NSSharingServicePicker(items: items).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }
    var holder: Holder
    func makeNSView(context: Context) -> NSView { let v = NSView(); holder.view = v; return v }
    func updateNSView(_ view: NSView, context: Context) { holder.view = view }
}
#endif
