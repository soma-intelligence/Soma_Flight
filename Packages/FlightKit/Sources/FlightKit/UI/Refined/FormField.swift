import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Contract
// - Name: `FormField` (I5, I12, I13).
// - Use: every text input in an editor (travel documents, past flight, booking, profile, phone number).
//   Never a bare `TextField` with its label only in the placeholder.
// - Variants: single line or multi-line (`axis: .vertical`), secure; a keyboard (`Keyboard`), a content type
//   (`Content`), a capitalization (`Capitalization`), a submit label; `next` moves focus to the next field
//   on Return (focus chaining), else `onSubmit` runs.
// - States: empty (prompt), filled, focused (accent rim), error (red rim and the error text under the
//   field), disabled (45 %), with an optional footnote under it when there is no error.
// - Tokens: Theme.card, Theme.separator, Theme.accent, Theme.veryLate (rim), Theme.veryLateText (error words),
//   Theme.secondary, Theme.Radius.control, 44 pt min height, Theme.Space.
// - A11y: the persistent label is the field's VoiceOver label; an error is its hint and is announced when it
//   appears. Keyboards with no Return key need `.keyboardDoneBar()` on the form.
// - Reduce Motion: no animation of its own.
// - Previews: below.

/// A labelled text field: a persistent label above the field, the field in a rounded control, and an inline
/// error or footnote under it.
public struct FormField<Field: Hashable>: View {
    /// The keyboard to show (iOS); ignored on the Mac.
    public enum Keyboard: Sendable { case standard, ascii, number, decimal, phone, email, url }
    /// What the field holds, for AutoFill and the QuickType bar. `.none` turns suggestions off (a document
    /// number must never get a one-time code suggested).
    public enum Content: Sendable {
        case none, name, givenName, familyName, email, phone, username, password, newPassword, oneTimeCode
        case flightNumber, postalCode, countryName, organization
    }
    public enum Capitalization: Sendable { case never, words, sentences, characters }

    var label: String
    @Binding var text: String
    var prompt: String?
    var error: String?
    var footnote: String?
    var keyboard: Keyboard
    var content: Content
    var capitalization: Capitalization
    var autocorrect: Bool
    var submitLabel: SubmitLabel
    var axis: Axis
    var isSecure: Bool
    var focus: FocusState<Field?>.Binding?
    var field: Field?
    var next: Field?
    var onSubmit: (() -> Void)?
    @Environment(\.metricsScale) private var scale
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var ownFocus: Bool

    /// - Parameters:
    ///   - label: shown above the field and read by VoiceOver.
    ///   - prompt: the placeholder, an example of the format ("AB1234567"); never the label.
    ///   - error: the inline error under the field; nil when valid.
    ///   - footnote: help under the field when there is no error.
    ///   - focus, field: the form's focus state and this field's value in it.
    ///   - next: the field Return moves to; when nil, Return runs `onSubmit`.
    public init(_ label: String, text: Binding<String>, prompt: String? = nil, error: String? = nil,
                footnote: String? = nil, keyboard: Keyboard = .standard, content: Content = .none,
                capitalization: Capitalization = .sentences, autocorrect: Bool = true,
                submitLabel: SubmitLabel = .next, axis: Axis = .horizontal, isSecure: Bool = false,
                focus: FocusState<Field?>.Binding, field: Field, next: Field? = nil, onSubmit: (() -> Void)? = nil) {
        self.label = label; _text = text; self.prompt = prompt; self.error = error; self.footnote = footnote
        self.keyboard = keyboard; self.content = content; self.capitalization = capitalization
        self.autocorrect = autocorrect; self.submitLabel = submitLabel; self.axis = axis; self.isSecure = isSecure
        self.focus = focus; self.field = field; self.next = next; self.onSubmit = onSubmit
    }

    private var isFocused: Bool {
        if let focus, let field { return focus.wrappedValue == field }
        return ownFocus
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.metric(Theme.Space.xs - 2, scale)) {
            Text(ui: label)
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            input
                .scaledFont(17)
                .foregroundStyle(Theme.primary)
                .scaledPadding(.horizontal, Theme.Space.sm)
                .scaledPadding(.vertical, Theme.Space.sm - 1)
                .frame(minHeight: Theme.metric(44, scale), alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.metric(Theme.Radius.control, scale), style: .continuous)
                    .fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.metric(Theme.Radius.control, scale), style: .continuous)
                    .strokeBorder(rim, lineWidth: error != nil || isFocused ? 1.5 : 1))
                .accessibilityLabel(Text(ui: label))
                .accessibilityHint(error.map { Text(ui: $0) } ?? Text(verbatim: ""))
            if let error {
                Label { Text(ui: error) } icon: { Image(systemName: "exclamationmark.circle.fill") }
                    .scaledFont(13, weight: .medium)
                    .foregroundStyle(Theme.veryLateText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            } else if let footnote {
                Text(ui: footnote)
                    .scaledFont(13)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .onChange(of: error) { _, new in
            #if os(iOS)
            if let new { AccessibilityNotification.Announcement(UIText.localized(new)).post() }
            #endif
        }
    }

    private var rim: Color {
        if error != nil { return Theme.veryLate }
        return isFocused ? Theme.accent : Theme.separator
    }

    @ViewBuilder private var input: some View {
        let promptText = prompt.map { Text(ui: $0) }
        Group {
            if isSecure {
                SecureField(text: $text, prompt: promptText) { Text(ui: label) }
            } else {
                TextField(text: $text, prompt: promptText, axis: axis) { Text(ui: label) }
            }
        }
        .modifier(FieldFocus(focus: focus, field: field, own: $ownFocus))
        .modifier(FieldTraits(keyboard: keyboard, content: content, capitalization: capitalization,
                              autocorrect: autocorrect))
        .submitLabel(submitLabel)
        .onSubmit {
            if let next, let focus { focus.wrappedValue = next } else { onSubmit?() }
        }
    }
}

public extension FormField where Field == Never {
    /// A field outside a focus chain.
    init(_ label: String, text: Binding<String>, prompt: String? = nil, error: String? = nil,
         footnote: String? = nil, keyboard: Keyboard = .standard, content: Content = .none,
         capitalization: Capitalization = .sentences, autocorrect: Bool = true,
         submitLabel: SubmitLabel = .done, axis: Axis = .horizontal, isSecure: Bool = false,
         onSubmit: (() -> Void)? = nil) {
        self.label = label; _text = text; self.prompt = prompt; self.error = error; self.footnote = footnote
        self.keyboard = keyboard; self.content = content; self.capitalization = capitalization
        self.autocorrect = autocorrect; self.submitLabel = submitLabel; self.axis = axis; self.isSecure = isSecure
        self.focus = nil; self.field = nil; self.next = nil; self.onSubmit = onSubmit
    }
}

/// Binds the field to the form's focus state when there is one, else to the field's own.
private struct FieldFocus<Field: Hashable>: ViewModifier {
    var focus: FocusState<Field?>.Binding?
    var field: Field?
    var own: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if let focus, let field {
            content.focused(focus, equals: field)
        } else {
            content.focused(own)
        }
    }
}

/// The keyboard, content type, capitalization and autocorrection, per platform.
private struct FieldTraits<Field: Hashable>: ViewModifier {
    var keyboard: FormField<Field>.Keyboard
    var content: FormField<Field>.Content
    var capitalization: FormField<Field>.Capitalization
    var autocorrect: Bool

    func body(content view: Content) -> some View {
        #if os(iOS)
        view
            .keyboardType(keyboardType)
            .textContentType(contentType)
            .textInputAutocapitalization(autocapitalization)
            .autocorrectionDisabled(!autocorrect)
        #else
        view.autocorrectionDisabled(!autocorrect)
        #endif
    }

    #if os(iOS)
    private var keyboardType: UIKeyboardType {
        switch keyboard {
        case .standard: .default
        case .ascii: .asciiCapable
        case .number: .numberPad
        case .decimal: .decimalPad
        case .phone: .phonePad
        case .email: .emailAddress
        case .url: .URL
        }
    }

    private var contentType: UITextContentType? {
        switch content {
        case .none: nil
        case .name: .name
        case .givenName: .givenName
        case .familyName: .familyName
        case .email: .emailAddress
        case .phone: .telephoneNumber
        case .username: .username
        case .password: .password
        case .newPassword: .newPassword
        case .oneTimeCode: .oneTimeCode
        case .flightNumber: .flightNumber
        case .postalCode: .postalCode
        case .countryName: .countryName
        case .organization: .organizationName
        }
    }

    private var autocapitalization: TextInputAutocapitalization {
        switch capitalization {
        case .never: .never
        case .words: .words
        case .sentences: .sentences
        case .characters: .characters
        }
    }
    #endif
}

#Preview("Form fields") {
    enum F: Hashable { case number, country }
    struct Demo: View {
        @State var number = ""
        @State var country = "France"
        @FocusState var focus: F?
        var body: some View {
            ScrollView {
                VStack(spacing: Theme.Space.md) {
                    FormField("Passport number", text: $number, prompt: "AB1234567", error: number.count == 3
                              ? "A passport number has 6 to 9 letters and digits." : nil,
                              keyboard: .ascii, capitalization: .characters, autocorrect: false,
                              focus: $focus, field: .number, next: .country)
                    FormField("Issuing country", text: $country, footnote: "As printed on the document.",
                              content: .countryName, capitalization: .words, submitLabel: .done,
                              focus: $focus, field: .country)
                    FormField("Notes", text: .constant(""), prompt: "Seat, meal, anything", axis: .vertical)
                }
                .padding(20)
            }
            .background(Theme.background)
            .keyboardDoneBar()
        }
    }
    return Demo()
}
