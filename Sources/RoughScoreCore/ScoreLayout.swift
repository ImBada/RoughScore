import Foundation

public struct ScoreMeasure: Identifiable, Equatable, Sendable {
    public let id: Int
    public let start: Double
    public let end: Double
    /// nil identifies an unmetered time block or the lead-in before the first detected bar.
    public let number: Int?
}

public struct ScoreSystem: Identifiable, Equatable, Sendable {
    public let id: Int
    public let measures: [ScoreMeasure]
    public var start: Double { measures.first!.start }
    public var end: Double { measures.last!.end }

    /// Each measure gets equal horizontal space, while note positions retain their original time.
    public func fraction(at time: Double) -> Double {
        guard let index = measures.firstIndex(where: { time < $0.end }) else { return 1 }
        let measure = measures[index]
        let within = min(1, max(0, (time - measure.start) / (measure.end - measure.start)))
        return (Double(index) + within) / Double(measures.count)
    }

    public func time(at fraction: Double) -> Double {
        let position = min(1, max(0, fraction)) * Double(measures.count)
        let index = min(measures.count - 1, Int(position))
        let measure = measures[index]
        return measure.start + min(1, position - Double(index)) * (measure.end - measure.start)
    }
}

public struct ScoreLayout: Equatable, Sendable {
    public let systems: [ScoreSystem]
    public let usesDetectedBars: Bool
    public let systemsPerPage: Int
    public var pageCount: Int { max(1, (systems.count + systemsPerPage - 1) / systemsPerPage) }

    public init(duration: Double, bars: [Double] = [], measuresPerSystem: Int = 4, systemsPerPage: Int = 4) {
        self.systemsPerPage = max(1, systemsPerPage)
        guard duration.isFinite, duration > 0 else { systems = []; usesDetectedBars = false; return }
        let sorted = bars.filter { $0.isFinite && $0 >= 0 && $0 < duration }.sorted()
        var detected: [Double] = []
        for time in sorted where detected.last.map({ time - $0 > 0.001 }) ?? true { detected.append(time) }
        let measured = !detected.isEmpty
        usesDetectedBars = measured
        let pickup = detected.first.map { $0 > 0.001 } ?? false
        var boundaries: [Double]
        if measured {
            boundaries = detected
            if pickup { boundaries.insert(0, at: 0) } else { boundaries[0] = 0 }
        } else {
            // No invented meter/BPM: use explicitly labeled two-second time blocks.
            boundaries = stride(from: 0.0, to: duration, by: 2.0).map { $0 }
        }
        boundaries.append(duration)
        let measures = (0..<(boundaries.count - 1)).map { index in
            ScoreMeasure(id: index, start: boundaries[index], end: boundaries[index + 1],
                         number: measured ? (pickup && index == 0 ? nil : index + (pickup ? 0 : 1)) : nil)
        }
        let count = min(8, max(1, measuresPerSystem))
        systems = stride(from: 0, to: measures.count, by: count).enumerated().map { row, offset in
            ScoreSystem(id: row, measures: Array(measures[offset..<min(measures.count, offset + count)]))
        }
    }

    public func page(at time: Double) -> Int {
        let index = systems.firstIndex(where: { time < $0.end }) ?? max(0, systems.count - 1)
        return index / systemsPerPage
    }

    public func rows(on page: Int) -> [ScoreSystem] {
        let offset = min(max(0, page), pageCount - 1) * systemsPerPage
        guard offset < systems.count else { return [] }
        return Array(systems[offset..<min(systems.count, offset + systemsPerPage)])
    }
}
