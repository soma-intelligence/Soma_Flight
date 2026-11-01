import SwiftUI

/// Settings > App Icon: one horizontal row per plane (Jet, Supersonic), every icon as a large preview with its
/// ground under it, the one in use
/// ringed in the accent colour. Tapping one asks the system to change it (iOS then shows its own short notice);
/// the ring moves to it at once and goes back if the system refuses.
struct AppIconPicker: View {
    /// Owned by Settings.
    var model: AppIconModel
    /// False lays the row out flat for snapshots (ImageRenderer cannot draw a scroll view's content).
    var scrolls = true
    @Namespace private var ring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.metricsScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AppIconPlane.allCases, id: \.self) { plane in
                VStack(alignment: .leading, spacing: 0) {
                    Text(plane.title.uppercased())
                        .scaledFont(11, weight: .semibold)
                        .foregroundStyle(Theme.secondary)
                        .scaledPadding(.horizontal, 16)
                        .scaledPadding(.top, plane == .jet ? 12 : 2)
                    if scrolls {
                        ScrollView(.horizontal, showsIndicators: false) { row(plane) }
                            .scrollClipDisabled()
                    } else {
                        // Laid out flat for snapshots: the row runs off the card's edge as it does before scrolling.
                        GeometryReader { geo in
                            row(plane).fixedSize().frame(width: geo.size.width, alignment: .leading)
                        }
                        .frame(height: Theme.metric(116, scale))
                        .clipped()
                    }
                }
            }
            if model.failed {
                Text("The icon could not be changed. Try again in a moment.")
                    .scaledFont(13).foregroundStyle(Theme.veryLate)
                    .scaledPadding(.horizontal, 16)
            }
        }
    }

    private func row(_ plane: AppIconPlane) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(AppIcons.icons(for: plane)) { choice in
                tile(choice)
            }
        }
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.top, 8)
        .scaledPadding(.bottom, 10)
        // The ring slides to the new icon the moment it is tapped, and back if the system refuses.
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.72),
                   value: model.current)
    }

    private func tile(_ choice: AppIconChoice) -> some View {
        let selected = choice == model.current
        return Button {
            Task { await model.select(choice) }
        } label: {
            VStack(spacing: 8) {
                AppIconThumbnail(choice: choice, side: 64)
                    .padding(4)
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 72 * 0.25, style: .continuous)
                                .strokeBorder(Theme.accent, lineWidth: 2.5)
                                .matchedGeometryEffect(id: "ring", in: ring)
                        }
                    }
                    .scaleEffect(selected ? 1 : 0.94)
                Text(choice.label)
                    .scaledFont(12, weight: selected ? .semibold : .regular)
                    .foregroundStyle(selected ? Theme.primary : Theme.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 76)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.isAvailable || model.isChanging)
        .accessibilityLabel(choice.name)
        .accessibilityHint(choice.tagline)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The icon itself, from FlightKit's AppIconPreviews catalog by its preview image set
/// (`AppIconChoice.previewName`), which carries its light and dark look.
struct AppIconThumbnail: View {
    var choice: AppIconChoice
    var side: CGFloat = 60
    @Environment(\.metricsScale) private var scale

    var body: some View {
        let s = Theme.metric(side, scale)
        let shape = RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
        Image(choice.previewName, bundle: .module)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: s, height: s)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1.5)
            .accessibilityHidden(true)
    }
}
