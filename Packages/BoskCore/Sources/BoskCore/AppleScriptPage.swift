import Foundation

/// The rules for what other apps do to a page through AppleScript (`set URL`, `execute ... javascript`).
public enum AppleScriptPage {
    /// The page a script may load with `set URL of tab`: http, https or about:blank only.
    /// A javascript: URL would run JavaScript with Allow JavaScript from Apple Events off,
    /// and a file: URL would show the user's files to the script.
    public static func url(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased() == "about:blank" { return URL(string: "about:blank") }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }

    /// The value an `execute` returns to the script for a JavaScript result, made here because
    /// Cocoa scripting throws when it must convert a result for the type "any" itself.
    /// Text stays as it is (callers often return JSON text and parse it). Arrays and objects
    /// become JSON text, because AppleScript has no type for most of them. undefined and null
    /// give missing value.
    public static func value(_ result: Any?) -> NSAppleEventDescriptor {
        switch result {
        case nil, is NSNull:
            return NSAppleEventDescriptor(typeCode: missingValue)
        case let text as String:
            return NSAppleEventDescriptor(string: text)
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return NSAppleEventDescriptor(boolean: number.boolValue)
        case let number as NSNumber where number.doubleValue == number.doubleValue.rounded() && abs(number.doubleValue) <= Double(Int32.max):
            return NSAppleEventDescriptor(int32: number.int32Value)
        case let number as NSNumber:
            return NSAppleEventDescriptor(double: number.doubleValue)
        case let object? where JSONSerialization.isValidJSONObject(object):
            let json = (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) }
            return NSAppleEventDescriptor(string: json ?? "")
        case let other?:
            return NSAppleEventDescriptor(string: String(describing: other))
        }
    }

    /// AppleScript's missing value ('msng').
    static let missingValue: OSType = 0x6D73_6E67
}
