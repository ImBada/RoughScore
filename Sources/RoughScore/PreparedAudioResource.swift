import Foundation
import RoughScoreCore

/// Persistent generations are leased; scratch is explicitly created by the operation; borrowed
/// resources have no deletion authority. A URL, basename or manifest alone never grants ownership.
enum PreparedAudioResource: Sendable {
    case persistent(CachedAudioPreparation.Result)
    case scratch(OwnedAudioScratch)
    case borrowed

    func disposeScratch() { if case .scratch(let scratch) = self { scratch.dispose() } }
    func scratchPin() throws -> OwnedAudioScratch.Pin? {
        if case .scratch(let scratch) = self { return try scratch.pin() }
        return nil
    }
    func withPinnedFile<T>(_ url: URL, _ read: (URL) throws -> T) throws -> T {
        switch self {
        case .persistent(let result): try result.lease.withPinnedFile(url.lastPathComponent, read)
        case .scratch(let scratch): try scratch.withPinnedFile(url.lastPathComponent, read)
        case .borrowed: try read(url)
        }
    }
    var cached: CachedAudioPreparation.Result? {
        if case .persistent(let result) = self { return result }
        return nil
    }
}

/// Retained alongside a native file or an async read, rather than just around its initializer.
final class PreparedAudioFileAccess: @unchecked Sendable {
    let url: URL
    private let reader: OwnedArtifactCache.Lease.Reader?
    private let scratchReader: OwnedAudioScratch.Reader?
    init(resource: PreparedAudioResource, url: URL) throws {
        switch resource {
        case .persistent(let result):
            let reader = try result.lease.reader(url.lastPathComponent)
            self.reader = reader; scratchReader = nil; self.url = reader.url
        case .scratch(let scratch):
            let reader = try scratch.reader(url.lastPathComponent)
            self.reader = nil; scratchReader = reader; self.url = reader.url
        case .borrowed:
            reader = nil; scratchReader = nil; self.url = url
        }
    }
    func validate() throws { try reader?.validate(); try scratchReader?.validate() }
}

extension PreparedAudio {
    func fileAccess(for source: ListeningSource) throws -> PreparedAudioFileAccess {
        // Legacy/test scratch may still use a borrowed original for stereo.
        let ownership: PreparedAudioResource = source == .stereo && stereoURL == nil ? .borrowed : resource
        return try PreparedAudioFileAccess(resource: ownership, url: url(for: source))
    }
    static func cached(_ result: CachedAudioPreparation.Result, original: URL,
                       mapping: AssetTimeMapping? = nil) throws -> PreparedAudio {
        PreparedAudio(original: original, left: try result.lease.url(result.metadata.left),
            right: try result.lease.url(result.metadata.right), directory: result.lease.directoryURL,
            duration: result.metadata.duration, isMono: result.metadata.identity.channelCount == 1,
            leftPeaks: result.leftPeaks, rightPeaks: result.rightPeaks, identity: result.metadata.identity,
            stereoURL: try result.lease.url(result.metadata.stereo), mapping: mapping, resource: .persistent(result))
    }
}
