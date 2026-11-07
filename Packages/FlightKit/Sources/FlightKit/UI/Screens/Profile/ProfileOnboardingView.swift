import PhotosUI
import SwiftUI

/// The short screen after the first sign-in (and Settings > Profile to change it later): a big round photo
/// with a camera badge, first and last name prefilled from Apple or Google when they gave them, Continue,
/// and Later. Apple never gives a photo, so the avatar offers the library (and the camera on iPhone) and
/// falls back on initials on the user's colour.
public struct ProfileOnboardingView: View {
    public enum Mode: Sendable { case onboarding, edit }

    var store: ProfileStore
    var mode: Mode
    var onDone: () -> Void

    @State private var first = ""
    @State private var last = ""
    @State private var emoji = ""
    /// The picture chosen on this screen (not yet saved); `.keep` shows the stored one.
    @State private var change: ProfileStore.PhotoChange = .keep
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPicker = false
    @State private var showCamera = false
    @State private var loaded = false
    @State private var failed = false
    @FocusState private var focus: Field?
    @Environment(\.airportStaticControls) private var staticControls
    @ScaledMetric(relativeTo: .largeTitle) private var avatarSide: CGFloat = 128
    @ScaledMetric(relativeTo: .body) private var controlHeight: CGFloat = 54

    private enum Field: Hashable { case first, last, emoji }

    /// - Parameters:
    ///   - mode: `.onboarding` after sign-in (Continue and Later), `.edit` from Settings (Save; the emoji too).
    ///   - onDone: closes the screen (after a save, a Later or a Cancel).
    public init(store: ProfileStore, mode: Mode = .onboarding, onDone: @escaping () -> Void = {}) {
        self.store = store; self.mode = mode; self.onDone = onDone
        let draft = store.draft
        _first = State(initialValue: draft.firstName)
        _last = State(initialValue: draft.lastName)
        _emoji = State(initialValue: store.profile?.emoji ?? "")
    }

    /// The picture shown: the one chosen here, else the stored one (none after Remove).
    private var shownPhoto: Data? {
        switch change {
        case .keep: store.photo
        case .set(let data): data
        case .remove: nil
        }
    }

    private var typedName: String { DisplayName.join(first: first, last: last) }

    public var body: some View {
        // Content at least as tall as the screen, so the buttons sit at the bottom; large text or the keyboard
        // make it scroll (as on Sign In).
        GeometryReader { geo in
            scroller {
                page.frame(minHeight: geo.size.height)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            if mode == .edit {
                CloseButton(action: onDone).padding(.top, 16).padding(.trailing, 16)
            }
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let jpeg = AvatarImage.jpeg(from: data) {
                    withAnimation(CardMotion.animation) { change = .set(jpeg) }
                }
                pickerItem = nil
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in
                showCamera = false
                if let data, let jpeg = AvatarImage.jpeg(from: data) {
                    withAnimation(CardMotion.animation) { change = .set(jpeg) }
                }
            }
            .ignoresSafeArea()
        }
        #endif
        .task { await prefill() }
    }

    private var page: some View {
            VStack(spacing: 0) {
                Color.clear.frame(height: mode == .onboarding ? 72 : 56)
                avatar
                    .scaledPadding(.bottom, 22)
                header
                    .scaledPadding(.bottom, 26)
                fields
                privacy
                    .scaledPadding(.top, 12)
                Spacer(minLength: 32)
                actions
            }
            .scaledPadding(.horizontal, 20)
            .scaledPadding(.bottom, 24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
    }

    /// A scroll view on screen (large text, the keyboard); plain content in snapshots, which draw a scroll
    /// view's content blank.
    @ViewBuilder private func scroller<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if staticControls {
            content()
        } else {
            ScrollView { content() }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: Parts

    private var avatar: some View {
        let photo = shownPhoto
        return ZStack(alignment: .bottomTrailing) {
            UserAvatar(photo: photo, name: typedName.isEmpty ? nil : typedName, id: store.owner, size: avatarSide)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                .id(photo?.count ?? -1)
                .transition(CardMotion.transition)
            // The camera badge: solid accent with a ring of the page colour, so it reads over any photo.
            Image(systemName: "camera.fill")
                .font(.system(size: avatarSide * 0.12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: avatarSide * 0.3, height: avatarSide * 0.3)
                .background(Circle().fill(Theme.accent))
                .padding(avatarSide * 0.03)
                .background(Circle().fill(Theme.background))
        }
        .frame(maxWidth: .infinity)
        .overlay { photoMenu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo == nil ? "Add a photo" : "Change photo")
        .accessibilityAddTraits(.isButton)
    }

    /// The whole avatar opens the photo choices. Snapshots draw nothing here (ImageRenderer cannot draw a Menu).
    @ViewBuilder private var photoMenu: some View {
        if !staticControls {
            Menu {
                Button("Choose Photo", systemImage: "photo.on.rectangle") { showPicker = true }
                #if os(iOS)
                if CameraPicker.isAvailable {
                    Button("Take Photo", systemImage: "camera") { showCamera = true }
                }
                #endif
                if shownPhoto != nil {
                    Button("Remove Photo", systemImage: "trash", role: .destructive) {
                        withAnimation(CardMotion.animation) { change = .remove }
                    }
                }
            } label: {
                Color.clear.frame(width: avatarSide + 16, height: avatarSide + 16).contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(mode == .onboarding ? "Welcome aboard" : "Your profile")
                .scaledFont(30, weight: .bold, relativeTo: .largeTitle)
                .foregroundStyle(Theme.primary)
            Text(ui: subtitle)
                .scaledFont(16)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    /// Says where the prefill came from, so a name the user did not type is not a surprise.
    private var subtitle: String {
        guard mode == .onboarding else { return "Your name and photo, for the friends you add." }
        let filled = !first.isEmpty || !last.isEmpty
        switch store.identity?.provider {
        case .apple where filled: return "We used the name Apple shared. Add a photo and you're set."
        case .google where filled: return "We filled this in from Google. Change anything you like."
        default: return "Add your name and a photo so friends know it's you."
        }
    }

    private var fields: some View {
        VStack(spacing: 0) {
            field("First name", text: $first, focus: .first)
            Rectangle().fill(Theme.separator).frame(height: 1).scaledPadding(.leading, 16)
            field("Last name", text: $last, focus: .last)
            if mode == .edit {
                Rectangle().fill(Theme.separator).frame(height: 1).scaledPadding(.leading, 16)
                emojiField
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
    }

    @ViewBuilder private func field(_ prompt: String, text: Binding<String>, focus field: Field) -> some View {
        Group {
            if staticControls {
                Text(text.wrappedValue.isEmpty ? prompt : text.wrappedValue)
                    .foregroundStyle(text.wrappedValue.isEmpty ? Theme.secondary.opacity(0.75) : Theme.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: text, prompt: Text(ui: prompt).foregroundStyle(Theme.secondary.opacity(0.75)))
                    .textContentType(field == .first ? .givenName : .familyName)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .focused($focus, equals: field)
                    .submitLabel(field == .first ? .next : .done)
                    .onSubmit { if field == .first { focus = .last } else { focus = nil } }
                    .onChange(of: text.wrappedValue) { _, new in
                        if new.count > DisplayName.maxLength { text.wrappedValue = String(new.prefix(DisplayName.maxLength)) }
                    }
            }
        }
        .scaledFont(17)
        .textFieldStyle(.plain)
        .scaledPadding(.horizontal, 16)
        .frame(height: controlHeight)
    }

    private var emojiField: some View {
        HStack {
            Text("Emoji when there's no photo").scaledFont(17).foregroundStyle(Theme.primary)
            Spacer()
            if staticControls {
                Text(emoji.isEmpty ? "🙂" : emoji).scaledFont(22)
            } else {
                TextField("🙂", text: $emoji)
                    .scaledFont(22)
                    .multilineTextAlignment(.center)
                    .frame(width: 48)
                    .focused($focus, equals: .emoji)
                    .onChange(of: emoji) { _, new in
                        let clean = FriendsStore.cleanEmoji(new) ?? ""
                        if clean != new { emoji = clean }
                    }
                    .accessibilityLabel("Emoji")
            }
        }
        .scaledPadding(.horizontal, 16)
        .frame(height: controlHeight)
    }

    private var privacy: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock.fill").scaledFont(12, weight: .semibold)
            Text("Only friends you accept see your name and photo.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .scaledFont(13)
        .foregroundStyle(Theme.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaledPadding(.horizontal, 4)
    }

    private var canSave: Bool { !store.saving && (mode == .edit || !typedName.isEmpty || shownPhoto != nil) }

    private var actions: some View {
        VStack(spacing: 6) {
            if failed {
                Text("That didn't save. Check your connection and try again.")
                    .scaledFont(13)
                    .foregroundStyle(Theme.veryLate)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaledPadding(.bottom, 6)
            }
            Button(action: save) {
                Group {
                    if store.saving {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Text(mode == .onboarding ? "Continue" : "Save").scaledFont(17, weight: .semibold)
                    }
                }
                .foregroundStyle(canSave || store.saving ? Color.white : Theme.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: controlHeight)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(canSave || store.saving ? Theme.accent : Theme.pill))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            if mode == .onboarding {
                Button {
                    Task { await store.skip(); onDone() }
                } label: {
                    Text("Later")
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.saving)
            }
        }
    }

    // MARK: Actions

    private func prefill() async {
        guard !loaded else { return }
        loaded = true
        // Google's picture, offered as the starting photo (uploaded as the user's own only on Continue).
        if mode == .onboarding, store.photo == nil, let photo = await store.providerPhoto(), change == .keep {
            change = .set(photo)
        }
    }

    private func save() {
        focus = nil
        failed = false
        Task {
            let ok = await store.save(firstName: first, lastName: last, photo: change,
                                      emoji: mode == .edit ? FriendsStore.cleanEmoji(emoji) : nil,
                                      finishOnboarding: true)
            if ok {
                change = .keep
                onDone()
            } else {
                failed = true
            }
        }
    }
}

#if os(iOS)
/// The camera, for a profile photo taken on the spot (only offered when the device has one).
struct CameraPicker: UIViewControllerRepresentable {
    var onFinish: (Data?) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .front
        picker.allowsEditing = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (Data?) -> Void
        init(onFinish: @escaping (Data?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage
            onFinish(image?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
#endif

#if DEBUG
// MARK: - Previews

struct ProfileOnboardingPreview: View {
    var scenario: FakeProfileService.Scenario
    @State private var store: ProfileStore?

    var body: some View {
        Group {
            if let store { ProfileOnboardingView(store: store) } else { ProgressView() }
        }
        .task {
            let s = ProfileStore(service: FakeProfileService(scenario))
            await s.prepare(owner: FakeProfileService.userId)
            store = s
        }
    }
}

#Preview("Apple") { ProfileOnboardingPreview(scenario: .apple).preferredColorScheme(.dark) }
#Preview("Email") { ProfileOnboardingPreview(scenario: .email).preferredColorScheme(.dark) }
#Preview("Google") { ProfileOnboardingPreview(scenario: .google).preferredColorScheme(.dark) }
#endif
