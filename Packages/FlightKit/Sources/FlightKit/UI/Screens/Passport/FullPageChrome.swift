import SwiftUI

/// The page a Passport card opens, chosen by `page`. The iOS shell presents it full screen over the
/// sheet, the Mac shell as a sheet over the window; both pass `onClose` to clear `HomeModel.fullPage`.
public struct FullPageView: View {
    var page: FullPage
    @Bindable var store: PassportStore
    var lookup: (String) -> Airport?
    var onClose: () -> Void

    public init(page: FullPage, store: PassportStore, lookup: @escaping (String) -> Airport? = { _ in nil },
                onClose: @escaping () -> Void) {
        self.page = page; self.store = store; self.lookup = lookup; self.onClose = onClose
    }

    public var body: some View {
        switch page {
        case .passport: FullPassportView(store: store, lookup: lookup, onClose: onClose)
        case .delays: DelayStatsView(store: store, lookup: lookup, onClose: onClose)
        case .aircraftStats: AircraftStatsView(store: store, onClose: onClose)
        }
    }
}

/// What every full page shares: a top bar (close at the left, the title centred, share at the right),
/// the year chips, then the hero and the sections, scrolling, on the page's own colour. Share hands
/// over the hero rendered as an image (the whole page is not rendered yet).
struct FullPageChrome<Hero: View, Content: View>: View {
    var title: String
    @Binding var year: Int?
    var years: [Int]
    var scheme: ColorScheme
    var page: Color
    /// Changes whenever what the hero shows changes (`PassportStore.revision`), so the share image follows.
    var shareKey: Int
    var onClose: () -> Void
    @ViewBuilder var hero: Hero
    @ViewBuilder var content: Content

    @State private var shareImage: Image?
    @Environment(\.units) private var units
    @Environment(\.displayScale) private var displayScale
    @Environment(\.metricsScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 8)
                .scaledPadding(.bottom, 10)
            if !years.isEmpty {
                YearChips(years: years, selection: $year)
                    .scaledPadding(.bottom, 10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    content
                }
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 4)
                .scaledPadding(.bottom, 40)
            }
        }
        .background(page.ignoresSafeArea())
        .environment(\.colorScheme, scheme)
        .task(id: shareKey) { renderShareImage() }
    }

    private var topBar: some View {
        ZStack {
            Text(title)
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            HStack {
                RoundButton(systemImage: "xmark", label: "Close", action: onClose)
                Spacer()
                if let shareImage {
                    ShareLink(item: shareImage, preview: SharePreview(title, image: shareImage)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: Theme.metric(18, scale), weight: .medium))
                            .foregroundStyle(Theme.primary)
                            .frame(width: Theme.metric(44, scale), height: Theme.metric(44, scale))
                            .background(Circle().fill(RoundButton.fill))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share")
                }
            }
        }
    }

    /// The hero at phone width, rendered again whenever its figures change.
    @MainActor private func renderShareImage() {
        let card = hero
            .frame(width: 361)
            .padding(16)
            .background(page)
            .environment(\.units, units)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: card)
        renderer.scale = max(displayScale, 2)
        shareImage = renderer.cgImage.map { Image(decorative: $0, scale: renderer.scale) }
    }
}
