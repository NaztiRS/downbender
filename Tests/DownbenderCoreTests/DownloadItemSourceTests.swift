import Testing
import Foundation
@testable import DownbenderCore

@MainActor
@Test func downloadItemDefaultsToMediaSourceAndNoResumeData() {
    let item = DownloadItem(url: "u", title: "t", destination: URL(fileURLWithPath: "/tmp"))
    #expect(item.source == .media)
    #expect(item.resumeData == nil)
}

@MainActor
@Test func directFileSourceCarriesInfo() {
    let item = DownloadItem(url: "u", title: "t", destination: URL(fileURLWithPath: "/tmp"))
    let info = DirectFileInfo(suggestedName: "a.zip", sizeBytes: 1024, contentType: "application/zip")
    item.source = .directFile(info)
    #expect(item.source == .directFile(info))
    if case .directFile(let got) = item.source { #expect(got.sizeBytes == 1024) } else { Issue.record("wrong case") }
}
