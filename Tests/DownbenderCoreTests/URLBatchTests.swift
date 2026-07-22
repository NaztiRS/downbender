import Testing
import Foundation
@testable import DownbenderCore

@Test func splitExtractsEveryWebURLFromMixedText() {
    let text = "https://youtu.be/a\nhttps://example.com/b.zip   http://plain.org/c"
    #expect(URLBatch.split(text) == ["https://youtu.be/a", "https://example.com/b.zip", "http://plain.org/c"])
}

@Test func splitPassesPlainTextThroughUnchanged() {
    // No web URLs → the trimmed text travels as-is; the probe gives the real error.
    #expect(URLBatch.split("  not a url  ") == ["not a url"])
    #expect(URLBatch.split("https://only.one/v") == ["https://only.one/v"])
}

@Test func splitIgnoresNonWebSchemesAndEmptyInput() {
    #expect(URLBatch.split("   \n  ").isEmpty)
    // ftp token alongside a web URL: only the web URL is a batch entry.
    #expect(URLBatch.split("ftp://x.org/f https://a.com/v") == ["https://a.com/v"])
}
