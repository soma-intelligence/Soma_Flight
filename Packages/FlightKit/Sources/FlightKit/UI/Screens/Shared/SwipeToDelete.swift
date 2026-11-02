import SwiftUI

/// A row that slides left to show a red Delete button, like Mail's rows. The rows live in a plain
/// scroll view, not a List, so `swipeActions` is not available: this does the same by hand. A short
/// pull opens the button, a long or fast one deletes straight away, a tap anywhere on an open row
/// closes it. A vertical drag is left to the scroll view and the sheet.
struct SwipeToDelete: ViewModifier {
    var label: String
    var onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var resting: CGFloat = 0
    @State private var width: CGFloat = 0
    /// Set once a drag turns out horizontal; a vertical one never moves the row.
    @State private var horizontal: Bool?
    @State private var armed = false

    /// Where a let-go drag ends up.
    enum Outcome: Equatable { case closed, open, delete }

    /// The open button's width.
    static let buttonWidth: CGFloat = 84

    /// Past this share of the row's width (where it stops or where its speed carries it), the row
    /// deletes on release.
    static let deleteShare: CGFloat = 0.55

    static func outcome(offset: CGFloat, predicted: CGFloat, width: CGFloat) -> Outcome {
        guard width > 0 else { return .closed }
        if -offset > width * deleteShare || -predicted > width * 0.9 { return .delete }
        if -offset > buttonWidth / 2 || -predicted > buttonWidth * 1.5 { return .open }
        return .closed
    }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .overlay {
                // While open, the row itself only closes it: a tap there must not open the flight.
                if resting != 0 {
                    Color.clear.contentShape(Rectangle()).onTapGesture { close() }
                }
            }
            .background(alignment: .trailing) {
                if offset < 0 { deleteButton }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .simultaneousGesture(drag)
            .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, now in now }
            .clipped()
    }

    private var deleteButton: some View {
        Button(role: .destructive) { delete() } label: {
            Image(systemName: "trash.fill")
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(.white)
                .frame(width: max(-offset, 0))
                .frame(maxHeight: .infinity)
                .background(Color.red)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                let t = value.translation
                if horizontal == nil { horizontal = abs(t.width) > abs(t.height) * 1.3 }
                guard horizontal == true else { return }
                // No pull to the right past closed; a little give, not a slide.
                let raw = resting + t.width
                offset = raw > 0 ? raw / 6 : raw
                armed = -offset > width * Self.deleteShare
            }
            .onEnded { value in
                defer { horizontal = nil }
                guard horizontal == true else { return }
                switch Self.outcome(offset: offset, predicted: resting + value.predictedEndTranslation.width, width: width) {
                case .delete: delete()
                case .open: settle(-Self.buttonWidth)
                case .closed: close()
                }
            }
    }

    private func settle(_ x: CGFloat) {
        withAnimation(.spring(duration: 0.3, bounce: 0.1)) { offset = x; resting = x }
        armed = false
    }

    private func close() { settle(0) }

    private func delete() {
        withAnimation(.easeOut(duration: 0.2)) { offset = -width; resting = -width }
        armed = false
        onDelete()
        // A delete that fails leaves the row in the list: slide it back rather than leave it gone.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            close()
        }
    }
}

extension View {
    /// Slide left to delete (see `SwipeToDelete`).
    func swipeToDelete(_ label: String = "Delete", perform onDelete: @escaping () -> Void) -> some View {
        modifier(SwipeToDelete(label: label, onDelete: onDelete))
    }
}
