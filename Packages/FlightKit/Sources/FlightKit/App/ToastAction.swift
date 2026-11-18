import Foundation

/// The button a toast carries (I1): Undo after a removal, Retry after a failure. `HomeModel.showToast(_:action:)`
/// shows it; the toast's button calls `HomeModel.runToastAction()`.
public struct ToastAction: Identifiable {
    public let id = UUID()
    /// The button's word ("Undo", "Retry"), looked up in the catalog by the view.
    public let title: String
    public let run: @MainActor () async -> Void

    public init(_ title: String, run: @escaping @MainActor () async -> Void) {
        self.title = title; self.run = run
    }
}

extension ToastAction: Equatable {
    public static func == (a: ToastAction, b: ToastAction) -> Bool { a.id == b.id }
}
