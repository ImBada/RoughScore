import CryptoKit
import Foundation
import RoughScoreCore

/// App-owned view state only. No note data, selection, playback or undo history is serialized.
struct WorkspaceSession: Codable, Equatable, Sendable {
    var cursor = 0.0
    var lane = "left"
    var asset = "original"
    var assetID: UUID?
    var channel = "stereo"
    var windowStart = 0.0
    var windowLength = 12.0
    var rate: Float = 1
    var scoreView = true
    var measuresPerSystem = 4
    var scorePage = 0
    var showBothLanes = false
    var showScoreWaveforms = true
    var followScore = true
    var showLengths = false
    var snapToBeat = false
    var loopStart = 0.0
    var loopEnd = 4.0
    var looping = false

    func bounded(to project: ScoreProject, stemAvailable: Bool) -> Self {
        var value = self
        let duration = project.duration
        value.cursor = TimeBounds.clamp(cursor, duration: duration) ?? 0
        value.lane = GuitarLane(rawValue: lane)?.rawValue ?? "left"
        value.channel = ListeningSource(rawValue: channel)?.rawValue ?? "stereo"
        value.asset = asset == "importedGuitarStem" && stemAvailable && assetID != nil && assetID == project.stemAsset?.id
            ? asset : "original"
        value.assetID = value.asset == "original" ? project.originalAsset?.id : project.stemAsset?.id
        value.windowLength = windowLength.isFinite && windowLength > 0
            ? min(duration, max(min(0.25, duration), min(48, windowLength))) : min(12, duration)
        value.windowStart = windowStart.isFinite ? min(max(0, windowStart), max(0, duration - value.windowLength)) : 0
        // Only rates offered by the native control are supported.
        value.rate = [Float(0.5), 0.75, 1].contains(rate) ? rate : 1
        value.measuresPerSystem = min(8, max(1, measuresPerSystem))
        if !loopStart.isFinite || !loopEnd.isFinite || loopStart < 0 || loopEnd <= loopStart || loopStart >= duration {
            value.loopStart = 0; value.loopEnd = min(4, duration); value.looping = false
        } else {
            value.loopStart = loopStart; value.loopEnd = min(duration, loopEnd)
        }
        let role: AudioAsset.Role = value.asset == "original" ? .original : .importedGuitarStem
        let active = role == .original ? project.originalAsset : project.stemAsset
        let channel = ListeningSource(rawValue: value.channel) ?? .stereo
        let summary = project.analyses[project.analysisKey(asset: active, channel: .stereo)] ??
            project.analyses[project.analysisKey(asset: active, channel: channel)] ??
            project.analyses[project.analysisKey(asset: active, channel: .left)] ??
            project.analyses[project.analysisKey(asset: active, channel: .right)]
        let layout = ScoreLayout(duration: duration, bars: summary?.bars ?? [],
            measuresPerSystem: value.measuresPerSystem, systemsPerPage: showBothLanes ? 2 : 4)
        value.scorePage = followScore ? layout.page(at: value.cursor) : min(max(0, scorePage), layout.pageCount - 1)
        return value
    }
}

/// Reads are async and guarded by Workspace's load token. Small writes can be flushed on quit.
struct WorkspaceSessionStore: Sendable {
    var read: @Sendable (URL, ScoreProject) async throws -> WorkspaceSession?
    var write: @MainActor @Sendable (WorkspaceSession, URL, ScoreProject) throws -> Void
    static let disabled = Self(read: { _, _ in nil }, write: { _, _, _ in })

    static func documentIdentity(_ project: ScoreProject) -> String {
        let source = project.originalAsset.map { $0.id.uuidString } ?? project.audioPath ?? "no-audio"
        return project.title + "\u{0}" + source
    }

    static var live: Self {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return files(at: support.appendingPathComponent("RoughScore/WorkspaceSessions-v1", isDirectory: true))
    }

    static func files(at root: URL) -> Self {
        let files = SessionFiles(root: root)
        return Self(read: { url, project in
            let task = Task.detached(priority: .utility) { try files.read(url, project: project) }
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }, write: { try files.write($0, url: $1, project: $2) })
    }
}

private struct SessionFiles: Sendable {
    let root: URL
    static let limit = 16_384
    private struct Envelope: Codable {
        var owner = "RoughScore.WorkspaceSession"
        var version = 1
        var projectPath: String
        var identity: String
        var session: WorkspaceSession
    }
    private func path(_ url: URL) -> String { url.standardizedFileURL.path }
    private func identity(_ project: ScoreProject) -> String {
        // Relinking/duration/note edits retain the session; a different title or original asset does not.
        return digest(WorkspaceSessionStore.documentIdentity(project))
    }
    private func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func location(_ url: URL) -> URL { root.appendingPathComponent(digest(path(url)) + ".json") }
    private func regular(_ url: URL, directory: Bool = false) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        guard values.isSymbolicLink != true,
              directory ? values.isDirectory == true : values.isRegularFile == true && (values.fileSize ?? Int.max) <= Self.limit
        else { throw CocoaError(.fileReadCorruptFile) }
    }
    private func envelope(_ url: URL) throws -> Envelope {
        try regular(url)
        // Bound the actual read too, even if another writer replaces/grows the file after stat.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.limit + 1) ?? Data()
        guard data.count <= Self.limit else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(Envelope.self, from: data)
    }
    func read(_ url: URL, project: ScoreProject) throws -> WorkspaceSession? {
        let file = location(url)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try regular(root, directory: true)
        let record = try envelope(file)
        guard record.owner == "RoughScore.WorkspaceSession", record.version == 1,
              record.projectPath == path(url), record.identity == identity(project) else { return nil }
        return record.session
    }
    func write(_ session: WorkspaceSession, url: URL, project: ScoreProject) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try regular(root, directory: true)
        let file = location(url)
        if (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil {
            let prior = try envelope(file)
            // Refuse to overwrite a foreign, unsupported or corrupt file, including symlinks.
            guard prior.owner == "RoughScore.WorkspaceSession", prior.version == 1, prior.projectPath == path(url)
            else { throw CocoaError(.fileWriteFileExists) }
        }
        let data = try JSONEncoder().encode(Envelope(projectPath: path(url), identity: identity(project), session: session))
        guard data.count <= Self.limit else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: file, options: .atomic)
    }
}
