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
    /// The top bar's own colour (the Passport's violet bar); the page colour when nil.
    var bar: Color? = nil
    /// Paints the sections full width under the hero (the Passport's dark sections); nil keeps the page.
    var sectionBackground: Color? = nil
    /// The hero's side margin; 0 lets a panel run edge to edge.
    var heroInset: CGFloat = 16
    /// The unselected year chips' text.
    var chipInk: Color = Theme.secondary
    /// The chosen year chip's fill.
    var chipFill: Color = Theme.pill
    /// The close and share circles' fill; the grey round button fill when nil.
    var buttonFill: Color? = nil
    @ViewBuilder var hero: Hero
    @ViewBuilder var content: Content

    @State private var shareImage: Image?
    @State private var position = ScrollPosition(edge: .top)
    @Environment(\.units) private var units
    @Environment(\.displayScale) private var displayScale
    @Environment(\.metricsScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 8)
                .scaledPadding(.bottom, 10)
                .background((bar ?? page).ignoresSafeArea(edges: .top))
            if !years.isEmpty {
                YearChips(years: years, selection: $year, fill: chipFill, ink: chipInk)
                    .scaledPadding(.top, bar == nil ? 0 : 10)
                    .scaledPadding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                    .background(page)
            }
            ScrollView {
                if let sectionBackground {
                    VStack(alignment: .leading, spacing: 0) {
                        hero.scaledPadding(.horizontal, heroInset)
                        VStack(alignment: .leading, spacing: 0) { content }
                            .scaledPadding(.bottom, 40)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(sectionBackground)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        hero
                        content
                    }
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.top, 4)
                    .scaledPadding(.bottom, 40)
                }
            }
            .scrollPosition($position)
            // Pulled past either end, the scroll view shows the colour of the end it is pulled from.
            .background {
                if let sectionBackground {
                    VStack(spacing: 0) { page; sectionBackground }.ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .background(page.ignoresSafeArea())
        .environment(\.colorScheme, scheme)
        .task(id: shareKey) { renderShareImage() }
        #if DEBUG
        // Screenshot runs: `-scrollY <points>` opens the page scrolled that far.
        .task {
            let y = UserDefaults.standard.double(forKey: "scrollY")
            guard y > 0 else { return }
            try? await Task.sleep(for: .milliseconds(600))
            position.scrollTo(y: y)
        }
        #endif
    }

    private var topBar: some View {
        ZStack {
            Text(title)
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            HStack {
                RoundButton(systemImage: "xmark", label: "Close", fill: buttonFill, action: onClose)
                Spacer()
                if let shareImage {
                    ShareLink(item: shareImage, preview: SharePreview(title, image: shareImage)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: Theme.metric(18, scale), weight: .medium))
                            .foregroundStyle(Theme.primary)
                            .frame(width: Theme.metric(44, scale), height: Theme.metric(44, scale))
                            .background(Circle().fill(buttonFill ?? RoundButton.fill))
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
