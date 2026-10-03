import AppKit
import UniformTypeIdentifiers
import AVFoundation
import Foundation
import RoughScoreCore

/// Async boundaries are injected so late, failed and cancellation-ignoring services can be tested.
struct WorkspaceServices: Sendable {
    var prepare: @Sendable (URL, @escaping @Sendable (Double) async -> Void) async throws -> PreparedAudio
    var createDemo: @Sendable (ScoreProject) async throws -> URL
    var readProject: @Sendable (URL) async throws -> ScoreProject
    var analyze: @Sendable (URL, Double) async throws -> AnalysisSummary
    var analyzerVersion = "apple-musicunderstanding-v1"
    var makePlayer: @MainActor @Sendable (URL) throws -> any AudioPlayerTransport
    var prepareTransport: @MainActor @Sendable (PreparedAudio) throws -> Void = { _ in }
    var discardPreparedTransport: @MainActor @Sendable (PreparedAudio) -> Void = { _ in }
    var writeProject: @MainActor @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var chooseSaveDestination: @MainActor @Sendable (String) -> URL? = { title in
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title
        panel.allowedContentTypes = [UTType(filenameExtension: "roughscore") ?? .json]
        return panel.runModal() == .OK ? panel.url : nil
    }
    var nativeTextUndo: @MainActor @Sendable () -> NativeTextUndoTarget? = { NativeTextUndoTarget.active() }
    var fileExists: @Sendable (URL) -> Bool
    var lastProject: @MainActor @Sendable () -> URL?
    var rememberProject: @MainActor @Sendable (URL) -> Void

    @MainActor static var live: WorkspaceServices {
        let factory = AudioEngineTransportFactory()
        return WorkspaceServices(
        prepare: { try await AudioPreparation.prepare($0, progress: $1) },
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
        makePlayer: { try factory.player($0) },
        prepareTransport: { try factory.prepare($0) },
        discardPreparedTransport: { factory.discard($0) },
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        lastProject: { UserDefaults.standard.string(forKey: "lastProjectPath").map { URL(fileURLWithPath: $0) } },
        rememberProject: { UserDefaults.standard.set($0.path, forKey: "lastProjectPath") }
        )
    }
}
