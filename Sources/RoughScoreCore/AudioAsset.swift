import Foundation

/// The encoded source bytes identify content independently of its path.
public struct AudioContentIdentity: Codable, Equatable, Sendable {
    public var version = 1
    public var sha256: String
    public var channelCount: Int
    public var sampleRate: Double
    public var frameCount: Int64
    public var preparationVersion: Int
    public init(sha256: String, channelCount: Int, sampleRate: Double, frameCount: Int64, preparationVersion: Int = 1) {
        self.sha256 = sha256; self.channelCount = channelCount; self.sampleRate = sampleRate
        self.frameCount = frameCount; self.preparationVersion = preparationVersion
    }
    public func validated() throws -> Self {
        guard version == 1, preparationVersion == 1 else { throw ProjectError.unsupportedVersion }
        guard sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              (1...2).contains(channelCount), sampleRate.isFinite, sampleRate > 0, frameCount > 0
        else { throw ProjectError.invalidData }
        return self
    }
}

public struct AudioReference: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case external, contained }
    public var kind: Kind
    public var path: String
    public init(kind: Kind = .external, path: String) { self.kind = kind; self.path = path }
    public func validated() throws -> Self {
        guard !path.isEmpty, !path.contains("\0") else { throw ProjectError.invalidData }
        if kind == .contained {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !path.contains("\\"),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ProjectError.invalidData }
        } else if !path.hasPrefix("/") { throw ProjectError.invalidData }
        return self
    }
}

public struct AudioAsset: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case original, importedGuitarStem }
    public var version = 1
    public var id: UUID
    public var role: Role
    public var reference: AudioReference
    public var identity: AudioContentIdentity?
    /// original-song seconds = asset seconds + offset; padded 250ms audio uses -0.25.
    public var originalTimeOffset: Double
    public init(id: UUID = UUID(), role: Role = .original, reference: AudioReference,
                identity: AudioContentIdentity? = nil, originalTimeOffset: Double = 0) {
        self.id = id; self.role = role; self.reference = reference
        self.identity = identity; self.originalTimeOffset = originalTimeOffset
    }
    public func validated() throws -> Self {
        guard version == 1 else { throw ProjectError.unsupportedVersion }
        _ = try reference.validated(); _ = try identity?.validated()
        guard originalTimeOffset.isFinite, abs(originalTimeOffset) <= 86_400,
              role != .original || originalTimeOffset == 0 else { throw ProjectError.invalidData }
        return self
    }
}

public struct AnalysisProvenance: Codable, Equatable, Sendable {
    public var version = 1
    public var assetID: UUID
    public var identity: AudioContentIdentity
    public var channel: String
    public var analyzerVersion: String
    public var settings: String
    public init(assetID: UUID, identity: AudioContentIdentity, channel: String,
                analyzerVersion: String, settings: String = "default-v1") {
        self.assetID = assetID; self.identity = identity; self.channel = channel
        self.analyzerVersion = analyzerVersion; self.settings = settings
    }
    public func validated() throws -> Self {
        guard version == 1 else { throw ProjectError.unsupportedVersion }
        _ = try identity.validated()
        guard ["stereo", "left", "right"].contains(channel), !analyzerVersion.isEmpty, !settings.isEmpty
        else { throw ProjectError.invalidData }
        return self
    }
}
