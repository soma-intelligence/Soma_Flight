import SwiftUI

/// How the home screen lays out its map and cards, chosen from the window's shape rather than the device.
///
/// The iPhone Duo's inner screen is about 669 x 951 pt, so on an iPhone the shorter side of the window
/// decides, not the size class. A Pro Max
/// turned sideways reports a regular width but is only 440 pt tall, so it keeps the sheet. The Duo's cover
/// screen (466 x 678 pt) is narrower than `duoMinimumSide` and keeps the sheet too.
public enum HomeLayout: Equatable, Sendable {
    /// The map with a bottom sheet over it: an iPhone window whose shorter side is under `duoMinimumSide`,
    /// or an iPad in a compact width.
    case sheet
    /// The iPad's side panels over the map.
    case panels
    /// An iPhone window with a shorter side of at least 600 pt, held sideways.
    case duoSideways
    /// An iPhone window with a shorter side of at least 600 pt, held upright (or square).
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
