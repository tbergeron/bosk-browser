import Foundation

/// Chrome extension files (CRX3) and Chrome Web Store addresses.
public enum ChromeExtensionPackage {
    public enum Error: Swift.Error, Equatable {
        case notAnExtension
        case unsupportedVersion(UInt32)
        case badHeader
    }

    /// Chromium also refuses bigger headers; a real header is a few KB (signatures and keys).
    static let maximumHeaderSize: UInt32 = 1 << 20

    /// Returns the ZIP archive inside a CRX3 file. A plain ZIP file is returned as is.
    /// CRX3 layout: "Cr24", version (UInt32 LE, 3), header length N (UInt32 LE),
    /// N bytes of header (protobuf), then the ZIP archive.
    /// Bosk does not check the header signatures: the file comes over HTTPS from Google, or
    /// from the user's own disk.
    public static func zipArchive(from data: Data) throws -> Data {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return data } // "PK\u{3}\u{4}"
        guard bytes.count == 12, bytes.starts(with: Array("Cr24".utf8)) else { throw Error.notAnExtension }
        let version = littleEndian(bytes[4..<8])
        guard version == 3 else { throw Error.unsupportedVersion(version) }
        let headerSize = littleEndian(bytes[8..<12])
        guard headerSize <= maximumHeaderSize, data.count >= 12 + Int(headerSize) + 4 else { throw Error.badHeader }
        let zip = data.dropFirst(12 + Int(headerSize))
        guard zip.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { throw Error.badHeader }
        return Data(zip)
    }

    private static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// The extension ID in a Chrome Web Store page address, or nil for other pages.
    /// Works for chromewebstore.google.com/detail/<name>/<id> and the old
    /// chrome.google.com/webstore/detail/<name>/<id>.
    public static func webStoreExtensionID(from url: URL) -> String? {
        let host = url.host()?.lowercased() ?? ""
        let parts = url.pathComponents.filter { $0 != "/" }
        let detail: ArraySlice<String>
        if host == "chromewebstore.google.com", parts.first == "detail" {
            detail = parts.dropFirst()
        } else if host == "chrome.google.com", parts.starts(with: ["webstore", "detail"]) {
            detail = parts.dropFirst(2)
        } else {
            return nil
        }
        return detail.first(where: isExtensionID)
    }

    /// Chrome extension IDs are 32 letters from a to p.
    static func isExtensionID(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { ("a"..."p").contains($0) }
    }

    /// The download address of the CRX file for an extension ID.
    /// `prodversion` must be a recent Chrome version, or the store sends an old format.
    public static func downloadURL(forExtensionID id: String, chromeVersion: String = "140.0.0.0") -> URL? {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")
        components?.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&uc"),
        ]
        return components?.url
    }
}
