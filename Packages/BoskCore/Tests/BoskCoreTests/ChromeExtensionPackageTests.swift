import Foundation
import Testing
@testable import BoskCore

/// Installing a Chrome extension means: find its ID on the store page, download the CRX
/// file, and give WebKit the ZIP inside it. A mistake here means no extension installs,
/// or Bosk reads a damaged file.
struct ChromeExtensionPackageTests {
    let zip = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00])

    func crx(version: UInt32 = 3, header: Data = Data(repeating: 7, count: 20), body: Data? = nil) -> Data {
        var data = Data("Cr24".utf8)
        for value in [version, UInt32(header.count)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data + header + (body ?? zip)
    }

    @Test("The ZIP after the CRX3 header is what WebKit loads")
    func extractsZip() throws {
        #expect(try ChromeExtensionPackage.zipArchive(from: crx()) == zip)
    }

    @Test("A plain ZIP file (an unpacked extension that was zipped) installs as is")
    func plainZip() throws {
        #expect(try ChromeExtensionPackage.zipArchive(from: zip) == zip)
    }

    @Test("CRX2 is refused, because Chrome stopped using it and Bosk does not read it")
    func refusesCRX2() {
        #expect(throws: ChromeExtensionPackage.Error.unsupportedVersion(2)) {
            try ChromeExtensionPackage.zipArchive(from: crx(version: 2))
        }
    }

    @Test("A header length past the end of the file is refused, not read out of bounds")
    func refusesBadLength() {
        var data = crx()
        data.replaceSubrange(8..<12, with: [0xFF, 0xFF, 0x00, 0x00])
        #expect(throws: ChromeExtensionPackage.Error.badHeader) {
            try ChromeExtensionPackage.zipArchive(from: data)
        }
    }

    @Test("A web page saved as .crx is refused")
    func refusesOtherFiles() {
        #expect(throws: ChromeExtensionPackage.Error.notAnExtension) {
            try ChromeExtensionPackage.zipArchive(from: Data("<html>".utf8))
        }
    }

    @Test("The extension ID comes from both store address formats")
    func storeIDs() {
        let id = "ddkjiahejlhfcafbddmgiahcphecmpfh"
        let new = URL(string: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(id)?hl=en")!
        let old = URL(string: "https://chrome.google.com/webstore/detail/ublock-origin-lite/\(id)")!
        let short = URL(string: "https://chromewebstore.google.com/detail/\(id)")!
        #expect(ChromeExtensionPackage.webStoreExtensionID(from: new) == id)
        #expect(ChromeExtensionPackage.webStoreExtensionID(from: old) == id)
        #expect(ChromeExtensionPackage.webStoreExtensionID(from: short) == id)
    }

    @Test("Other store pages and other sites show no Add button")
    func noIDElsewhere() {
        #expect(ChromeExtensionPackage.webStoreExtensionID(from: URL(string: "https://chromewebstore.google.com/category/extensions")!) == nil)
        #expect(ChromeExtensionPackage.webStoreExtensionID(from: URL(string: "https://example.com/detail/ddkjiahejlhfcafbddmgiahcphecmpfh")!) == nil)
    }

    @Test("The download address asks for CRX3 for that ID")
    func downloadURL() {
        let url = ChromeExtensionPackage.downloadURL(forExtensionID: "ddkjiahejlhfcafbddmgiahcphecmpfh")!
        #expect(url.absoluteString.hasPrefix("https://clients2.google.com/service/update2/crx?"))
        #expect(url.absoluteString.contains("x=id%3Dddkjiahejlhfcafbddmgiahcphecmpfh%26uc"))
        #expect(url.absoluteString.contains("acceptformat=crx3"))
    }
}
