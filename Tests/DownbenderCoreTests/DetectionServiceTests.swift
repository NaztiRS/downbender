import Testing
@testable import DownbenderCore

@Test func classifyRoutesPlainFileExtensionsToDirect() {
    #expect(DetectionService.classify("https://example.com/a.zip") == .directFile)
    #expect(DetectionService.classify("https://example.com/path/report.PDF") == .directFile)
    #expect(DetectionService.classify("https://example.com/app.dmg") == .directFile)
    #expect(DetectionService.classify("https://example.com/pic.png?x=1") == .directFile)
}

@Test func classifyRoutesMediaExtensionsToMediaFile() {
    #expect(DetectionService.classify("https://example.com/clip.mp4") == .mediaFile)
    #expect(DetectionService.classify("https://cdn.example.com/song.mp3") == .mediaFile)
}

@Test func classifyRoutesExtensionlessAndPagesToProbe() {
    #expect(DetectionService.classify("https://youtu.be/abc123") == .probe)
    #expect(DetectionService.classify("https://example.com/download?id=42") == .probe)
    #expect(DetectionService.classify("https://example.com/watch") == .probe)
}
