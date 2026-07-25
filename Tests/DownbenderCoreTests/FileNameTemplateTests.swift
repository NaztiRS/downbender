import Foundation
import Testing
@testable import DownbenderCore

private func templateArguments(
    fileNameTemplate: String = FileNameTemplate.defaultValue
) -> [String] {
    DownloadArgsBuilder.arguments(
        url: "https://youtu.be/template-test",
        format: .audioMP3,
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
        ffmpegDirectory: URL(fileURLWithPath: "/app/ffmpeg"),
        fileNameTemplate: fileNameTemplate
    )
}

private func outputTemplate(in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "-o"),
          arguments.indices.contains(index + 1)
    else { return nil }
    return arguments[index + 1]
}

@MainActor
private func makeFileNameTemplateModel(
    defaults: UserDefaults,
    runner: ProcessRunning = FakeProcessRunner(),
    root: URL
) -> AppModel {
    AppModel(
        binaries: BundledBinaries(
            ytdlp: URL(fileURLWithPath: "/fake/yt-dlp"),
            ffmpegDirectory: URL(fileURLWithPath: "/fake/ffmpeg"),
            deno: nil
        ),
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: root.appendingPathComponent("tmp", isDirectory: true),
        appSupportDirectory: root.appendingPathComponent("support", isDirectory: true),
        cookiesBrowser: nil,
        runner: runner,
        defaults: defaults,
        directSessionFactory: { FailingURLProtocol.session() }
    )
}

@MainActor
private func waitForFileNameTemplateItems(_ items: [DownloadItem]) async {
    var attempts = 0
    while items.contains(where: { item in
        switch item.state {
        case .queued, .downloading, .merging: true
        default: false
        }
    }), attempts < 400 {
        attempts += 1
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Test func fileNameTemplateAcceptsSafeYtdlpFieldsAndLiteralPercents() {
    let values = [
        FileNameTemplate.defaultValue,
        "%(uploader)s - %(title)s [%(id)s].%(ext)s",
        "%(upload_date)s - %(title).80B.%(ext)s",
        "100%% %(title)s.%(ext)s",
        "Vídeo — %(title)s.%(ext)s",
        "%(title)200s.%(ext)s",
        "%(title).200s.%(ext)s",
    ]

    for value in values {
        #expect(FileNameTemplate.validationMessage(for: value) == nil)
        #expect(FileNameTemplate.normalized(value) == value)
    }
    #expect(FileNameTemplate.normalized("  %(title)s.%(ext)s  ") == "%(title)s.%(ext)s")
}

@Test func fileNameTemplatePresetsAreUniqueValidAndRecognized() {
    let presets = FileNameTemplate.Preset.allCases
    let expected: [(FileNameTemplate.Preset, String)] = [
        (.title, "%(title)s.%(ext)s"),
        (.channelAndTitle, "%(channel)s — %(title)s.%(ext)s"),
        (.uploadDateAndTitle, "%(upload_date)s — %(title)s.%(ext)s"),
        (.titleAndIdentifier, "%(title)s [%(id)s].%(ext)s"),
    ]
    let templates = expected.map(\.1)

    #expect(presets == expected.map(\.0))
    #expect(Set(templates).count == presets.count)
    for (preset, template) in expected {
        #expect(preset.template == template)
        #expect(FileNameTemplate.normalized(template) == template)
        #expect(FileNameTemplate.Preset.matching("  \(template)  ") == preset)
    }
    #expect(FileNameTemplate.Preset.matching("%(uploader)s - %(title)s.%(ext)s") == nil)
    #expect(FileNameTemplate.Preset.matching("../%(title)s.%(ext)s") == nil)
}

@Test func fileNameTemplateExamplesRenderPresetsAndCustomFields() {
    #expect(FileNameTemplate.example(for: FileNameTemplate.Preset.title.template) == "My video.mp4")
    #expect(
        FileNameTemplate.example(for: FileNameTemplate.Preset.uploadDateAndTitle.template)
            == "20260725 — My video.mp4"
    )
    #expect(
        FileNameTemplate.example(for: "100%% %(uploader)s - %(title)s [%(id)s].%(ext)s")
            == "100% Example Creator - My video [a1b2c3].mp4"
    )
    #expect(
        FileNameTemplate.example(for: "%%(title)s - %(title)s.%(ext)s")
            == "%(title)s - My video.mp4"
    )
    #expect(FileNameTemplate.example(for: "%(title).1s.%(ext)s") == nil)
    #expect(FileNameTemplate.example(for: "../%(title)s.%(ext)s") == nil)
}

@Test func fileNameTemplateRejectsUnsafeNamesAndMalformedPlaceholders() {
    let tooLong = String(repeating: "a", count: FileNameTemplate.maximumLength + 1)
    let invalidValues = [
        "",
        "   ",
        "../%(title)s.%(ext)s",
        #"folder\%(title)s.%(ext)s"#,
        "thumbnail:%(title)s.%(ext)s",
        "%(title)s",
        "%(title)s.%(ext)s.%(ext)s",
        "%(title",
        "%title.%(ext)s",
        "100% %(title)s.%(ext)s",
        "line\n%(title)s.%(ext)s",
        "%(unknown)s.%(ext)s",
        "%(ext)s",
        "-%(title)s.%(ext)s",
        "$HOME-%(title)s.%(ext)s",
        "${HOME}-%(title)s.%(ext)s",
        "~-%(title)s.%(ext)s",
        "%(title)*s.%(ext)s",
        "%(title)201s.%(ext)s",
        "%(title).201s.%(ext)s",
        tooLong,
    ]

    for value in invalidValues {
        #expect(FileNameTemplate.validationMessage(for: value) != nil, "unexpectedly accepted: \(value)")
        #expect(FileNameTemplate.normalized(value) == nil)
    }
}

@Test func downloadArgsUseDefaultAndCustomFileNameTemplates() {
    #expect(outputTemplate(in: templateArguments()) == "%(title)s.%(ext)s")

    let custom = "%(uploader)s - %(title)s [%(id)s].%(ext)s"
    #expect(outputTemplate(in: templateArguments(fileNameTemplate: custom)) == custom)
}

@Test func downloadArgsFallBackToSafeDefaultForInvalidTemplate() {
    #expect(
        outputTemplate(in: templateArguments(fileNameTemplate: "../outside/%(title)s.%(ext)s"))
            == "%(title)s.%(ext)s"
    )
}

@MainActor
@Test func validFileNameTemplatePersistsAndInvalidValuePreservesIt() {
    let suite = "filename-template-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("filename-template-\(UUID().uuidString)", isDirectory: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    let first = makeFileNameTemplateModel(defaults: defaults, root: root)
    #expect(FileNameTemplate.outputTemplate(for: first.fileNameTemplate) == "%(title)s.%(ext)s")

    let custom = "%(uploader)s - %(title)s.%(ext)s"
    #expect(first.setFileNameTemplate(custom))
    #expect(defaults.string(forKey: AppModel.fileNameTemplateKey) == custom)

    let restored = makeFileNameTemplateModel(defaults: defaults, root: root)
    #expect(restored.fileNameTemplate == custom)
    #expect(!restored.setFileNameTemplate("../escape/%(title)s.%(ext)s"))
    #expect(restored.fileNameTemplate == custom)
    #expect(defaults.string(forKey: AppModel.fileNameTemplateKey) == custom)

    restored.resetFileNameTemplate()
    #expect(restored.fileNameTemplate == FileNameTemplate.defaultValue)
    #expect(defaults.object(forKey: AppModel.fileNameTemplateKey) == nil)
}

@MainActor
@Test func lastCustomFileNameTemplateSurvivesPresetChangesAndRelaunch() {
    let suite = "filename-template-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("filename-template-\(UUID().uuidString)", isDirectory: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    let custom = "%(uploader)s - %(title)s.%(ext)s"
    let first = makeFileNameTemplateModel(defaults: defaults, root: root)
    #expect(first.setFileNameTemplate(custom))
    #expect(first.lastCustomFileNameTemplate == custom)
    #expect(defaults.string(forKey: AppModel.lastCustomFileNameTemplateKey) == custom)

    let preset = FileNameTemplate.Preset.channelAndTitle.template
    #expect(first.setFileNameTemplate(preset))
    #expect(first.fileNameTemplate == preset)
    #expect(first.lastCustomFileNameTemplate == custom)

    let restored = makeFileNameTemplateModel(defaults: defaults, root: root)
    #expect(restored.fileNameTemplate == preset)
    #expect(restored.lastCustomFileNameTemplate == custom)

    let replacement = "%(id)s - %(title)s.%(ext)s"
    #expect(restored.setFileNameTemplate(replacement))
    restored.resetFileNameTemplate()
    #expect(restored.fileNameTemplate == FileNameTemplate.defaultValue)
    #expect(restored.lastCustomFileNameTemplate == replacement)
    #expect(defaults.string(forKey: AppModel.lastCustomFileNameTemplateKey) == replacement)
}

@MainActor
@Test func legacyCustomFileNameTemplateIsRememberedWhenChoosingAPreset() {
    let suite = "filename-template-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("filename-template-\(UUID().uuidString)", isDirectory: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    let legacyCustom = "%(uploader)s - %(title)s.%(ext)s"
    defaults.set(legacyCustom, forKey: AppModel.fileNameTemplateKey)
    #expect(defaults.object(forKey: AppModel.lastCustomFileNameTemplateKey) == nil)

    let upgraded = makeFileNameTemplateModel(defaults: defaults, root: root)
    #expect(upgraded.fileNameTemplate == legacyCustom)
    #expect(upgraded.lastCustomFileNameTemplate == nil)
    #expect(upgraded.setFileNameTemplate(FileNameTemplate.Preset.uploadDateAndTitle.template))
    #expect(upgraded.lastCustomFileNameTemplate == legacyCustom)

    let restored = makeFileNameTemplateModel(defaults: defaults, root: root)
    #expect(restored.fileNameTemplate == FileNameTemplate.Preset.uploadDateAndTitle.template)
    #expect(restored.lastCustomFileNameTemplate == legacyCustom)
}

@MainActor
@Test func invalidOrPresetLastCustomFileNameTemplateIsDiscarded() {
    let suite = "filename-template-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("filename-template-\(UUID().uuidString)", isDirectory: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    defaults.set(
        FileNameTemplate.Preset.titleAndIdentifier.template,
        forKey: AppModel.lastCustomFileNameTemplateKey
    )
    let presetModel = makeFileNameTemplateModel(defaults: defaults, root: root)
    #expect(presetModel.lastCustomFileNameTemplate == nil)
    #expect(defaults.object(forKey: AppModel.lastCustomFileNameTemplateKey) == nil)

    defaults.set("../%(title)s.%(ext)s", forKey: AppModel.lastCustomFileNameTemplateKey)
    let invalidModel = makeFileNameTemplateModel(defaults: defaults, root: root)
    #expect(invalidModel.lastCustomFileNameTemplate == nil)
    #expect(defaults.object(forKey: AppModel.lastCustomFileNameTemplateKey) == nil)
}

@MainActor
@Test func corruptPersistedFileNameTemplateFallsBackToDefault() {
    let suite = "filename-template-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("filename-template-\(UUID().uuidString)", isDirectory: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    defaults.set("../../outside", forKey: AppModel.fileNameTemplateKey)

    let model = makeFileNameTemplateModel(defaults: defaults, root: root)
    #expect(model.fileNameTemplate == FileNameTemplate.defaultValue)
    #expect(FileNameTemplate.outputTemplate(for: model.fileNameTemplate) == "%(title)s.%(ext)s")
}

@MainActor
@Test func choosingFormatSnapshotsTemplateBeforeTheQueuedItemStarts() async {
    let suite = "filename-template-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("filename-template-\(UUID().uuidString)", isDirectory: true)
    let runner = FakeProcessRunner(stdoutLines: ["DBPATH /tmp/out.mp3"])
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let model = makeFileNameTemplateModel(defaults: defaults, runner: runner, root: root)
    model.queue.setMaxConcurrent(0)
    let item = DownloadItem(
        url: "https://youtu.be/queued",
        title: "Queued",
        destination: URL(fileURLWithPath: "/tmp/dest"),
        state: .readyToChoose
    )
    model.queue.add(item)

    let selectedTemplate = "%(uploader)s - %(title)s.%(ext)s"
    #expect(model.setFileNameTemplate(selectedTemplate))
    model.choose(.audioMP3, for: item)
    #expect(item.state == .queued)
    #expect(item.fileNameTemplate == selectedTemplate)

    #expect(model.setFileNameTemplate("%(id)s.%(ext)s"))
    #expect(item.fileNameTemplate == selectedTemplate)
    model.queue.setMaxConcurrent(1)
    await waitForFileNameTemplateItems([item])

    #expect(item.state == .done)
    #expect(
        outputTemplate(in: runner.recordedArguments.arguments) == selectedTemplate
    )
}

@MainActor
@Test func acceptingPlaylistSnapshotsTemplateForEveryEntry() async {
    let suite = "filename-template-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("filename-template-\(UUID().uuidString)", isDirectory: true)
    let runner = FakeProcessRunner(stdoutLines: ["DBPATH /tmp/out.mp3"])
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let model = makeFileNameTemplateModel(defaults: defaults, runner: runner, root: root)
    model.queue.setMaxConcurrent(0)
    let selectedTemplate = "%(upload_date)s - %(title)s.%(ext)s"
    #expect(model.setFileNameTemplate(selectedTemplate))

    model.acceptPlaylist(
        PlaylistProbe(
            title: "Playlist",
            entries: [
                PlaylistEntry(url: "https://youtu.be/one", title: "One"),
                PlaylistEntry(url: "https://youtu.be/two", title: "Two"),
            ]
        ),
        format: .audioMP3
    )
    let items = model.queue.items
    #expect(items.count == 2)
    #expect(items.allSatisfy { $0.state == .queued })
    #expect(items.allSatisfy { $0.fileNameTemplate == selectedTemplate })

    #expect(model.setFileNameTemplate("%(id)s.%(ext)s"))
    #expect(items.allSatisfy { $0.fileNameTemplate == selectedTemplate })
    model.queue.setMaxConcurrent(2)
    await waitForFileNameTemplateItems(items)

    #expect(items.allSatisfy { $0.state == .done })
    #expect(runner.recordedArguments.allArguments.count == 2)
    for arguments in runner.recordedArguments.allArguments {
        #expect(outputTemplate(in: arguments) == selectedTemplate)
    }
}

@MainActor
@Test func persistedQueueWithoutFileNameTemplateFieldStillLoads() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("filename-template-\(UUID().uuidString)", isDirectory: true)
    let file = root.appendingPathComponent("queue.json")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = QueuePersistence(fileURL: file)
    let item = DownloadItem(
        url: "https://youtu.be/old-queue",
        title: "Old queue item",
        format: .audioMP3,
        destination: URL(fileURLWithPath: "/tmp/dest"),
        state: .downloading
    )
    store.saveNow([item])

    let encoded = try Data(contentsOf: file)
    guard var rootObject = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
          var items = rootObject["items"] as? [[String: Any]],
          !items.isEmpty
    else {
        Issue.record("queue fixture did not encode as the expected object")
        return
    }
    items[0].removeValue(forKey: "fileNameTemplate")
    items[0].removeValue(forKey: "filenameTemplate")
    rootObject["items"] = items
    let legacyData = try JSONSerialization.data(withJSONObject: rootObject, options: [.sortedKeys])
    try legacyData.write(to: file, options: .atomic)

    let loaded = store.load()
    #expect(loaded.count == 1)
    let restored = loaded.first?.makeItem()
    #expect(restored?.state == .paused)
    #expect(restored?.fileNameTemplate == FileNameTemplate.defaultValue)
}
