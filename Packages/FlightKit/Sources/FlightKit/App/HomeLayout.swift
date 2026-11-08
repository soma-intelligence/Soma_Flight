import SwiftUI

/// How the home screen lays out its map and cards, chosen from the window's shape rather than the device.
///
/// The Surface Duo-style foldable iPhone reports a compact size class on its inner screen (626 x 890 pt),
/// so the size class cannot be trusted there: the shorter side of the window decides instead. A Pro Max
/// turned sideways reports a regular width but is only 440 pt tall, so it keeps the sheet. The Duo's cover
/// screen (466 x 678 pt) is narrower than `duoMinimumSide` and keeps the sheet too.
public enum HomeLayout: Equatable, Sendable {
    /// The map with a bottom sheet over it: every iPhone, and an iPad in a narrow window.
    case sheet
    /// The iPad's side panels over the map.
    case panels
    /// An iPhone window wide enough for two panes, held sideways.
    case duoSideways
    /// An iPhone window wide enough for two panes, held upright (or square).
    case duoUpright

    /// The shorter window side from which an iPhone screen gets the Duo layouts.
    public static let duoMinimumSide: CGFloat = 600

    /// Picks the layout. On an iPad the width class decides; on an iPhone only the window's size does, and
    /// `regularWidth` is ignored.
    public static func resolve(isPad: Bool, regularWidth: Bool, size: CGSize) -> HomeLayout {
        if isPad { return regularWidth ? .panels : .sheet }
        guard min(size.width, size.height) >= duoMinimumSide else { return .sheet }
        return size.width > size.height ? .duoSideways : .duoUpright
    }

    /// `.duoSideways` or `.duoUpright`.
    public var isDuo: Bool { self == .duoSideways || self == .duoUpright }
}
