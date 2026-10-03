import Foundation

/// Shared L/R tuning. Recorded frets are relative to the capo; labels alone never imply an octave.
public struct TuningDefinition: Codable, Equatable, Sendable {
    public static let standard = TuningDefinition()
    public static let dropD = TuningDefinition(openMIDIPitches: [64, 59, 55, 50, 45, 38])

    public static func pitchName(_ midi: Int) -> String {
        guard (0...127).contains(midi) else { return "?" }
        return ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"][midi % 12] + String(midi / 12 - 1)
    }

    public var name: String {
        switch openMIDIPitches {
        case Self.standard.openMIDIPitches: "Standard"
        case Self.dropD.openMIDIPitches: "Drop D"
        default: "Custom"
        }
    }
    public var version = 1
    public var openMIDIPitches: [Int]
    public var capo: Int
    public init(openMIDIPitches: [Int] = [64, 59, 55, 50, 45, 40], capo: Int = 0) {
        self.openMIDIPitches = openMIDIPitches; self.capo = capo
    }
    public func validated() throws -> Self {
        guard version == 1 else { throw ProjectError.unsupportedVersion }
        guard openMIDIPitches.count == 6, (0...24).contains(capo),
              openMIDIPitches.allSatisfy({ (0...127).contains($0) && $0 + capo <= 127 })
        else { throw ProjectError.invalidData }
        return self
    }
}
