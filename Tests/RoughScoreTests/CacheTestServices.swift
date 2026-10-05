import Foundation
@testable import RoughScore
@testable import RoughScoreCore

extension WorkspaceServices {
    /// Every test store lives in a unique disposable root. Tests never touch the app's default cache/settings.
    @MainActor static func isolatedCache() -> WorkspaceServices {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("RoughScore-test-cache-" + UUID().uuidString)
        var services = cachedLive(environment: try! AudioCacheEnvironment(configuration: .init(root: root)))
        services.lastProject = { nil }; services.rememberProject = { _ in }
        services.chooseSaveDestination = { _ in nil }
        return services
    }
}
