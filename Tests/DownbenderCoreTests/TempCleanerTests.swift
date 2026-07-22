import Testing
import Foundation
@testable import DownbenderCore

private func makeTmpDir(files: [String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in files {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8))
    }
    return dir
}

@Test func sweepEmptiesTheDirectoryWhenNothingIsResumable() throws {
    let dir = try makeTmpDir(files: ["a.part", "b.f137.mp4.part", "c.tmp"])
    defer { try? FileManager.default.removeItem(at: dir) }
    TempCleaner.sweep(tmpDirectory: dir, keepResumables: false)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}

@Test func sweepKeepsFreshFilesWhenResumablesExist() throws {
    let dir = try makeTmpDir(files: ["fresh.part"])
    defer { try? FileManager.default.removeItem(at: dir) }
    TempCleaner.sweep(tmpDirectory: dir, keepResumables: true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["fresh.part"])
}

@Test func sweepRemovesStaleFilesEvenWithResumables() throws {
    let dir = try makeTmpDir(files: ["stale.part", "fresh.part"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let old = Date(timeIntervalSinceNow: -40 * 24 * 3600)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.appendingPathComponent("stale.part").path)
    TempCleaner.sweep(tmpDirectory: dir, keepResumables: true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["fresh.part"])
}

@Test func sweepToleratesAMissingDirectory() {
    TempCleaner.sweep(tmpDirectory: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)"), keepResumables: false)
    // no throw, no crash — nothing to assert beyond reaching this line
}
