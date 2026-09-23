import SwiftUI
import UIKit

func dismissInputKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// Keep the secure input's UIKit identity stable while SwiftUI updates form validation.
struct AccountSecureField: UIViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var contentType: UITextContentType? = .password
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.isSecureTextEntry = true; field.textContentType = contentType
        field.overrideUserInterfaceStyle = .light; field.textColor = UIColor(Theme.ink)
        field.backgroundColor = .white
        field.autocapitalizationType = .none; field.autocorrectionType = .no
        field.borderStyle = .roundedRect; field.placeholder = placeholder
        field.accessibilityIdentifier = placeholder
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        field.placeholder = placeholder
        if field.textContentType != contentType { field.textContentType = contentType }
        if !field.isFirstResponder && field.text != text { field.text = text }
    }
    final class Coordinator: NSObject {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        @objc func changed(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
    }
}
