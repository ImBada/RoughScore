import AppKit
import UniformTypeIdentifiers
import AVFoundation
import Foundation
import RoughScoreCore

/// Async boundaries are injected so late, failed and cancellation-ignoring services can be tested.
struct WorkspaceServices: Sendable {
    var detectPitch: @Sendable (URL, Double) async throws -> DetectedPitch? = { try await AudioPreparation.detectPitch($0, at: $1) }
    var prepare: @Sendable (URL, @escaping @Sendable (Double) async -> Void) async throws -> PreparedAudio
    var align: @Sendable (PreparedAudio, AudioAsset, Double) async throws -> PreparedAudio = {
        try await AudioPreparation.alignedStem($0, asset: $1, duration: $2)
    }
    var sessionStore: WorkspaceSessionStore = .disabled
    var exportServices = ScoreExportServices()
    var cacheEnvironment: AudioCacheEnvironment? = nil
    var createDemo: @Sendable (ScoreProject) async throws -> URL
    var readProject: @Sendable (URL) async throws -> ScoreProject
    var analyze: @Sendable (URL, Double) async throws -> AnalysisSummary
    var analysisInputMode: AudioCacheEnvironment.SummaryInputMode = .descriptor
    var analyzerVersion = "apple-musicunderstanding-v1"
    var makePlayer: @MainActor @Sendable (PreparedAudio, ListeningSource) throws -> any AudioPlayerTransport
    var prepareTransport: @MainActor @Sendable (PreparedAudio) throws -> Void = { _ in }
    var discardPreparedTransport: @MainActor @Sendable (PreparedAudio) -> Void = { _ in }
    var writeProject: @MainActor @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var readPackage: @Sendable (URL) async throws -> PortableProjectPackage.Snapshot = { url in
        let task = Task.detached(priority: .userInitiated) { try PortableProjectPackage.read(at: url) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    var collectPackage: @MainActor @Sendable (ScoreProject, URL, URL?, () throws -> Void) throws -> PortableProjectPackage.Snapshot = {
        try PortableProjectPackage.collect($0, to: $1, sourceRoot: $2, cancellation: $3, verifyingExpectedIdentities: true)
    }
    var updatePackage: @MainActor @Sendable (ScoreProject, PortableProjectPackage.Snapshot, () throws -> Void) throws -> PortableProjectPackage.Snapshot = {
        try PortableProjectPackage.update($0, replacing: $1, cancellation: $2)
    }
    var chooseSaveDestination: @MainActor @Sendable (ProjectSaveRequest) -> URL? = { $0.choose() }
    var nativeTextUndo: @MainActor @Sendable () -> NativeTextUndoTarget? = { NativeTextUndoTarget.active() }
    var fileExists: @Sendable (URL) -> Bool
    var initialProject: @MainActor @Sendable () -> URL? = {
        initialProjectURL(arguments: CommandLine.arguments)
    }
    var lastProject: @MainActor @Sendable () -> URL?
    var rememberProject: @MainActor @Sendable (URL) -> Void

    static func initialProjectURL(arguments: [String]) -> URL? {
        arguments.dropFirst().first(where: {
            ["roughscore", PortableProjectPackage.fileExtension].contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
        }).map { URL(fileURLWithPath: $0) }
    }

    @MainActor static var live: WorkspaceServices {
        switch AudioCacheEnvironment.shared {
        case .success(let environment):
            var services = cachedLive(environment: environment)
            services.sessionStore = .live
            return services
        case .failure(let error):
            var services = cachedLive(environment: nil)
            services.sessionStore = .live
            services.prepare = { _, _ in throw error }
            return services
        }
    }

    @MainActor static func cachedLive(environment: AudioCacheEnvironment?) -> WorkspaceServices {
        let factory = AudioEngineTransportFactory()
        return WorkspaceServices(
        prepare: { url, progress in
            guard let environment else { throw AudioIssue.unavailable }
            return try PreparedAudio.cached(await environment.preparation.prepare(url, progress: progress), original: url)
        },
        align: { raw, asset, duration in
            guard let environment, let cached = raw.resource.cached else {
                return try await AudioPreparation.alignedStem(raw, asset: asset, duration: duration)
            }
            return try PreparedAudio.cached(await environment.preparation.align(cached, asset: asset, duration: duration),
                original: raw.original, mapping: AssetTimeMapping(asset: asset, originalDuration: duration))
        },
        cacheEnvironment: environment,
        createDemo: { project in
            let task = Task.detached(priority: .userInitiated) { try AudioPreparation.createDemo(project: project) }
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        },
        readProject: { url in
            let task = Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: url)).validated()
            }
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        },
        analyze: { try await AppleMusicAnalysis.analyze($0, duration: $1) },
        analysisInputMode: .canonicalFile,
        makePlayer: { try factory.player($0, source: $1) },
        prepareTransport: { try factory.prepare($0) },
        discardPreparedTransport: { factory.discard($0) },
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        lastProject: { UserDefaults.standard.string(forKey: "lastProjectPath").map { URL(fileURLWithPath: $0) } },
        rememberProject: { UserDefaults.standard.set($0.path, forKey: "lastProjectPath") }
        )
    }
}
