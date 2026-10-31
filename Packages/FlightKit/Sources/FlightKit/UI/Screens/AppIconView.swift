#if os(iOS)
import SwiftUI
import UIKit

/// Settings > App Icon: every icon with its name and tagline, the one in use checked. Tapping one asks the
/// system to change it (iOS then shows its own short notice).
struct AppIconView: View {
    @State private var model = AppIconModel(setter: SystemAppIconSetting())

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("App Icon")
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.top, 22)
                .scaledPadding(.bottom, 16)
            ScrollView {
                VStack(spacing: 0) {
                    if model.failed {
                        Text("The icon could not be changed. Try again in a moment.")
                            .scaledFont(14).foregroundStyle(Theme.veryLate)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .scaledPadding(.horizontal, 16).scaledPadding(.bottom, 10)
                    }
                    Hairline().scaledPadding(.horizontal, 16)
                    ForEach(AppIcons.all) { choice in
                        AppIconRow(choice: choice, selected: choice == model.current,
                                   last: choice == AppIcons.all.last) {
                            Task { await model.select(choice) }
                        }
                        .disabled(!model.isAvailable || model.isChanging)
                    }
                    Hairline().scaledPadding(.horizontal, 16)
                }
                .scaledPadding(.bottom, 32)
            }
        }
        .background(Theme.background)
    }
}

/// One icon: its picture, name and tagline, and a check when it is the one in use.
struct AppIconRow: View {
    var choice: AppIconChoice
    var selected: Bool
    var last: Bool
    var action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 14) {
                    AppIconThumbnail(choice: choice)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.name).scaledFont(17, weight: .semibold).foregroundStyle(Theme.primary)
                        Text(choice.tagline).scaledFont(14).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(22)
                        .foregroundStyle(Theme.accent)
                        .opacity(selected ? 1 : 0)
                }
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if !last { Hairline().scaledPadding(.leading, 90).scaledPadding(.trailing, 16) }
        }
    }
}

/// The icon itself, read from the app's asset catalog by its set name; a plain tile with the first letter
/// when the catalog has no image under that name.
struct AppIconThumbnail: View {
    var choice: AppIconChoice
    @Environment(\.metricsScale) private var scale

    var body: some View {
        let side = Theme.metric(60, scale)
        let shape = RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
        Group {
            if let image = UIImage(named: choice.assetName ?? "AppIcon") {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.pill
                    Text(String(choice.name.prefix(1))).scaledFont(26, weight: .bold).foregroundStyle(Theme.secondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.separator, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
#endif
