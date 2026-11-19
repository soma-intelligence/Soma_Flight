import SwiftUI

/// The three sheet headers of the app, and no other (R5).
/// - `.root`: large title on the left, an avatar or one action on the right (My Flights, Friends, Passport).
/// - `.detail`: a leading mark, a small caps overline, a 20 pt bold title, optional actions and the glass
///   close button (flight, airport, friend).
/// - `.modal`: a centred 17 pt semibold title, Close or Cancel on the left, Done on the right when something
///   can be saved (Settings, Travel documents, Profile, Search).
/// Penpot: Header/Root, Header/Detail, Header/Modal
public struct SheetHeader: View {
    /// What sits on the left of a modal header.
    public enum ModalLeading {
        /// The 44 pt glass close button.
        case close(() -> Void)
        /// The word "Cancel", in the accent colour.
        case cancel(() -> Void)
    }

    public enum Kind {
        case root(title: String, trailing: AnyView? = nil)
        case detail(overline: String, title: String, mark: AnyView? = nil, actions: AnyView? = nil,
                    onClose: (() -> Void)? = nil)
        case modal(title: String, leading: ModalLeading, onDone: (() -> Void)? = nil, doneDisabled: Bool = false)
    }

    var kind: Kind
    @Environment(\.metricsScale) private var scale

    public init(_ kind: Kind) { self.kind = kind }

    /// The room above and below a tab's root header (My Flights, Friends, Passport), the same on all three
    /// so the large title sits at one height and a tab change slides it sideways without a hop.
    public static let rootTop: CGFloat = 16
    public static let rootBottom: CGFloat = 6

    /// A root header with a trailing avatar or action.
    public static func root<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> SheetHeader {
        SheetHeader(.root(title: title, trailing: AnyView(trailing())))
    }

    /// A detail header with a leading mark (an airline logo, an airport glyph, an avatar) and trailing actions.
    public static func detail<Mark: View, Actions: View>(
        overline: String, title: String, onClose: (() -> Void)?,
        @ViewBuilder mark: () -> Mark, @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) -> SheetHeader {
        SheetHeader(.detail(overline: overline, title: title, mark: AnyView(mark()), actions: AnyView(actions()),
                            onClose: onClose))
    }

    public var body: some View {
        switch kind {
        case let .root(title, trailing): root(title, trailing)
        case let .detail(overline, title, mark, actions, onClose): detail(overline, title, mark, actions, onClose)
        case let .modal(title, leading, onDone, disabled): modal(title, leading, onDone, disabled)
        }
    }

    // MARK: Root

    private func root(_ title: String, _ trailing: AnyView?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(ui: title)
                .scaledFont(34, weight: .bold)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
        .scaledPadding(.horizontal, Theme.gutter)
        .scaledPadding(.vertical, 4)
        .frame(minHeight: Theme.metric(52, scale))
    }

    // MARK: Detail

    private func detail(_ overline: String, _ title: String, _ mark: AnyView?, _ actions: AnyView?,
                        _ onClose: (() -> Void)?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let mark {
                mark
                    .frame(width: Theme.metric(36, scale), height: Theme.metric(36, scale))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(ui: overline)
                    .scaledFont(11, weight: .semibold)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Text(ui: title)
                    .themeFont(.sheetTitle)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let actions {
                HStack(spacing: 8) { actions }
            }
            if let onClose {
                CloseButton(inset: false, action: onClose)
            }
        }
        .scaledPadding(.horizontal, Theme.gutter)
        .scaledPadding(.vertical, 6)
        .frame(minHeight: Theme.metric(56, scale))
    }

    // MARK: Modal

    private func modal(_ title: String, _ leading: ModalLeading, _ onDone: (() -> Void)?, _ disabled: Bool) -> some View {
        ZStack {
            Text(ui: title)
                .themeFont(.sectionTitle)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .scaledPadding(.horizontal, 88)
                .accessibilityAddTraits(.isHeader)
            HStack {
                switch leading {
                case .close(let action):
                    CloseButton(inset: false, action: action)
                case .cancel(let action):
                    textButton("Cancel", weight: .regular, action: action)
                }
                Spacer(minLength: 8)
                if let onDone {
                    textButton("Done", weight: .semibold, action: onDone)
                        .disabled(disabled)
                        .opacity(disabled ? 0.4 : 1)
                }
            }
        }
        .scaledPadding(.horizontal, Theme.gutter)
        .scaledPadding(.vertical, 6)
        .frame(minHeight: Theme.metric(56, scale))
    }

    private func textButton(_ label: String, weight: Font.Weight, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(ui: label)
                .scaledFont(17, weight: weight)
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("Sheet headers") {
    VStack(spacing: 24) {
        SheetHeader.root("My Flights") {
            Circle().fill(Theme.accent.opacity(0.16)).frame(width: 36, height: 36)
                .overlay(Text("CL").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent))
        }
        SheetHeader.detail(overline: "AF 84 · Tue, 17 Nov", title: "Paris to San Francisco", onClose: {}) {
            Image(systemName: "airplane").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.primary)
        }
        SheetHeader(.modal(title: "Settings", leading: .close {}))
        SheetHeader(.modal(title: "Travel documents", leading: .cancel {}, onDone: {}))
    }
    .padding(.vertical, 20)
    .background(Theme.background)
}
