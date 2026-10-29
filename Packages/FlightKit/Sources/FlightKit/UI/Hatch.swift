import SwiftUI

/// White fill with thin diagonal lines: the "canceled" texture on bars and legends.
struct Hatch: View {
    var spacing: CGFloat = 4

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.canceled))
            var p = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            ctx.stroke(p, with: .color(.gray.opacity(0.55)), lineWidth: 1)
        }
    }
}
