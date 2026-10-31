import SwiftUI

extension View {
    /// Shows the boarding pass a user opened in the app (`HomeModel.passImport`) while its flight is looked
    /// up, offered to follow, or refused. The shells attach it where their other sheets hang.
    public func passImportSheet(_ home: HomeModel) -> some View {
        modifier(PassImportPresenter(home: home))
    }
}

private struct PassImportPresenter: ViewModifier {
    var home: HomeModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { home.passImport }, set: { home.passImport = $0 })) { pending in
            PassImportSheet(pending: pending, onFollow: { Task { await home.followAndKeepPass() } },
                            onClose: { home.passImport = nil })
                .presentationDetents([.medium])
                #if os(macOS)
                .frame(width: 420, height: 380)
                #endif
        }
    }
}

/// The pass, then what can be done with it.
struct PassImportSheet: View {
    var pending: PassImport
    var onFollow: () -> Void
    var onClose: () -> Void
    @State private var following = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Boarding Pass")
                    .scaledFont(22, weight: .bold)
                    .foregroundStyle(Theme.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                RoundButton(systemImage: "xmark", label: "Close", action: onClose)
            }
            if let pass = pending.pass {
                BoardingPassTicket(pass: pass, flight: nil, origin: nil)
            }
            content
            Spacer(minLength: 0)
        }
        .scaledPadding(.all, 20)
        .background(Theme.background.ignoresSafeArea())
        .onChange(of: pending.state) { following = false }
    }

    @ViewBuilder private var content: some View {
        switch pending.state {
        case .lookingUp:
            HStack(spacing: 10) {
                ProgressView()
                Text("Finding the flight").scaledFont(16).foregroundStyle(Theme.secondary)
            }
        case .follow(let flight):
            Text("You do not follow \(Format.ident(flight.ident)) yet. Follow it to keep this boarding pass with the flight.")
                .scaledFont(16)
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                following = true
                onFollow()
            } label: {
                Group {
                    if following { ProgressView() } else { Text("Follow \(Format.ident(flight.ident))") }
                }
                .scaledFont(17, weight: .semibold)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Theme.accent)
            .disabled(following)
        case .failed(let text):
            message(text)
        case .notFound:
            message(pending.pass.map(PassImportFacts.notFound) ?? PassImportFacts.unreadable)
        case .unreadable:
            message(PassImportFacts.unreadable)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .scaledFont(16)
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview("Import, follow offer") {
    PassImportSheet(pending: PassImport(pass: FakeBoardingPass.af84(now: PreviewData.now), walletFile: nil,
                                        state: .follow(PreviewData.enRoute)),
                    onFollow: {}, onClose: {})
        .preferredColorScheme(.dark)
}
#endif
