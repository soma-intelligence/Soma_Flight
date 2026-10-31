import FlightWatchKit
import SwiftUI

/// The boarding pass at the gate: the barcode as large as the screen allows, black on white, with the
/// passenger and the group under it. The modules come drawn from the phone (watchOS has no Core Image);
/// this view only paints them, each one a whole number of points so a scanner reads clean edges.
struct WatchPassScreen: View {
    let pass: WatchPass
    let ident: String

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let modules = pass.modules, modules.isValid {
                    BarcodeView(matrix: modules)
                        .padding(pass.isSquare ? 10 : 6)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel("Boarding pass barcode")
                } else {
                    Label("Open the pass on your iPhone", systemImage: "iphone")
                        .font(.footnote)
                        .foregroundStyle(ActivityPalette.secondary)
                }
                if let alt = pass.altText {
                    Text(alt).font(.caption2.monospaced()).foregroundStyle(ActivityPalette.secondary)
                }
                if let passenger = pass.passenger {
                    Text(passenger).font(.headline)
                }
                if let group = pass.boardingGroup {
                    Text("Group \(group)").font(.subheadline).foregroundStyle(ActivityPalette.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(ident)
    }
}

/// Paints a `BarcodeMatrix`: dark modules on transparent, sized to the width offered, a whole number of
/// pixels per module, no smoothing.
struct BarcodeView: View {
    let matrix: BarcodeMatrix
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geo in
            let pixels = max(1, (geo.size.width * scale / CGFloat(matrix.width)).rounded(.down))
            let module = pixels / scale
            Canvas(rendersAsynchronously: false) { context, _ in
                var path = Path()
                for y in 0..<matrix.height {
                    var x = 0
                    // One rectangle per run of dark modules on a row.
                    while x < matrix.width {
                        guard matrix[x, y] else { x += 1; continue }
                        let start = x
                        while x < matrix.width, matrix[x, y] { x += 1 }
                        path.addRect(CGRect(x: CGFloat(start) * module, y: CGFloat(y) * module,
                                            width: CGFloat(x - start) * module, height: module))
                    }
                }
                context.fill(path, with: .color(.black))
            }
            .frame(width: module * CGFloat(matrix.width), height: module * CGFloat(matrix.height))
            .frame(maxWidth: .infinity)
        }
        .aspectRatio(CGFloat(matrix.width) / CGFloat(matrix.height), contentMode: .fit)
    }
}

#Preview("Pass") {
    let snapshot = WatchSnapshot.preview()
    let pass = snapshot.extras.compactMap(\.pass).first!
    return NavigationStack { WatchPassScreen(pass: pass, ident: "UA 1527") }
}
