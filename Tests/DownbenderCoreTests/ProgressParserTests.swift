import Testing
import Foundation
@testable import DownbenderCore

// Template ↔ parser CONTRACT: substitute each %(...)s with a representative yt-dlp value and
// parse the result; a reordered or dropped field breaks here instead of silently in production.
@Test func progressTemplateRoundTripsThroughParser() {
    var line = DownloadArgsBuilder.progressTemplate
    #expect(line.hasPrefix("download:"))
    line.removeFirst("download:".count)

    let substitutions = [
        "%(progress._percent_str)s": " 42.0%",
        "%(progress.downloaded_bytes)s": "4404019",
        "%(progress.total_bytes,progress.total_bytes_estimate)s": "10485760",
        "%(progress._speed_str)s": " 4.20MiB/s",
        "%(progress._eta_str)s": "00:42",
    ]
    for (field, value) in substitutions {
        #expect(line.contains(field), "the template lost the field \(field)")
        line = line.replacingOccurrences(of: field, with: value)
    }
    #expect(!line.contains("%("), "the template has fields this test does not know: \(line)")

    let p = ProgressParser.parse(line: line)
    #expect(p != nil)
    #expect(abs((p?.fraction ?? 0) - 0.42) < 0.0001)
    #expect(p?.downloadedBytes == 4_404_019)
    #expect(p?.totalBytes == 10_485_760)
    #expect(p?.speedText == "4.20MiB/s")
    #expect(p?.etaText == "00:42")
}

@Test func progressParserReadsValidLine() {
    let p = ProgressParser.parse(line: "DBPROG  42.0% 4404019 10485760 4.20MiB/s 00:42")
    #expect(p != nil)
    #expect(abs((p?.fraction ?? 0) - 0.42) < 0.0001)
    #expect(p?.downloadedBytes == 4_404_019)
    #expect(p?.totalBytes == 10_485_760)
    #expect(p?.speedText == "4.20MiB/s")
    #expect(p?.etaText == "00:42")
}

@Test func progressParserHandlesNABytes() {
    let p = ProgressParser.parse(line: "DBPROG  42.0% NA NA 4.20MiB/s 00:42")
    #expect(p?.downloadedBytes == nil)
    #expect(p?.totalBytes == nil)
    #expect(p?.speedText == "4.20MiB/s")
    #expect(p?.etaText == "00:42")
}

@Test func progressParserParsesFloatTotalEstimate() {
    // total_bytes_estimate arrives as a float ("10485760.0")
    let p = ProgressParser.parse(line: "DBPROG   5.0% 524288 10485760.0 1.00MiB/s 01:00")
    #expect(p?.downloadedBytes == 524_288)
    #expect(p?.totalBytes == 10_485_760)
}

@Test func progressParserHidesUnknownSpeedAndNAEta() {
    // Real yt-dlp lines: "Unknown B/s" (internal space) and an "NA" eta when finishing.
    let first = ProgressParser.parse(line: "DBPROG   0.2% 1024 629172 Unknown B/s")
    #expect(first?.speedText == "")
    #expect(first?.etaText == "")
    let last = ProgressParser.parse(line: "DBPROG 100.0% 629172 629172 196.79KiB/s NA")
    #expect(last?.speedText == "196.79KiB/s")
    #expect(last?.etaText == "")
}

@Test func progressParserIgnoresNonProgressAndNA() {
    #expect(ProgressParser.parse(line: "[youtube] Extracting URL") == nil)
    #expect(ProgressParser.parse(line: "DBPROG NA NA NA") == nil)
    #expect(ProgressParser.parse(line: "") == nil)
}
