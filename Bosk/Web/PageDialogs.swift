import AppKit

/// Sheets for page dialogs (alert, confirm, prompt, sign-in) and the error page.
@MainActor
enum PageDialogs {
    static func alert(_ message: String, host: String?, in window: NSWindow) async {
        let alert = makeAlert(message, host: host)
        alert.addButton(withTitle: "OK")
        _ = await alert.beginSheetModal(for: window)
    }

    static func confirm(_ message: String, host: String?, in window: NSWindow,
                        confirmTitle: String = "OK", cancelTitle: String = "Cancel") async -> Bool {
        let alert = makeAlert(message, host: host)
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    static func prompt(_ message: String, defaultText: String?, host: String?, in window: NSWindow) async -> String? {
        let alert = makeAlert(message, host: host)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// HTTP sign-in (Basic, Digest, NTLM). Bosk does not save the password.
    static func signIn(host: String, in window: NSWindow) async -> (String, String)? {
        let alert = NSAlert()
        alert.messageText = "Sign in to \(host)"
        alert.informativeText = "Your password is sent to this site only. Bosk does not save it."
        let user = NSTextField(frame: NSRect(x: 0, y: 32, width: 280, height: 24))
        user.placeholderString = "User name"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        password.placeholderString = "Password"
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        stack.addSubview(user)
        stack.addSubview(password)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = user
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
        return (user.stringValue, password.stringValue)
    }

    private static func makeAlert(_ message: String, host: String?) -> NSAlert {
        let alert = NSAlert()
        if let host, !host.isEmpty {
            alert.messageText = "“\(host)” says:"
            alert.informativeText = message
        } else {
            alert.messageText = message
        }
        return alert
    }

    static func errorPage(message: String, url: URL?) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let address = escape(url?.absoluteString ?? "")
        return """
            <!doctype html><meta charset="utf-8"><title>Page did not open</title>
            <meta name="color-scheme" content="light dark">
            <style>
              body { font: 15px -apple-system, sans-serif; display: grid; place-items: center; height: 90vh; margin: 0; }
              main { max-width: 480px; text-align: center; }
              h1 { font-size: 20px; } p { color: GrayText; word-break: break-all; }
              button { font: inherit; padding: 6px 16px; }
            </style>
            <main><h1>\(escape(message))</h1><p>\(address)</p>
            <button onclick="location.href = '\(address.replacingOccurrences(of: "'", with: "%27"))'">Try Again</button></main>
            """
    }
}
