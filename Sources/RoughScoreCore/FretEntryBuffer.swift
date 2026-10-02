import Foundation

public struct FretEntryUpdate: Equatable, Sendable {
    public let fret: Int
    public let startsNewEntry: Bool

    public init(fret: Int, startsNewEntry: Bool) {
        self.fret = fret
        self.startsNewEntry = startsNewEntry
    }
}

/// Groups the two keystrokes of a fret from 10 through 24 into one edit.
public struct FretEntryBuffer: Sendable {
    private struct PendingDigit: Sendable {
        let digit: Int
        let eventID: UUID
        let time: Double
    }

    private var pending: PendingDigit?

    public init() {}

    public mutating func push(digit: Int, eventID: UUID, now: Double) -> FretEntryUpdate? {
        guard (0...9).contains(digit), now.isFinite else {
            reset()
            return nil
        }

        if let pending, pending.eventID == eventID,
           now >= pending.time, now - pending.time <= 0.9 {
            let fret = pending.digit * 10 + digit
            reset()
            guard fret <= 24 else { return nil }
            return FretEntryUpdate(fret: fret, startsNewEntry: false)
        }

        pending = (digit == 1 || digit == 2) ? PendingDigit(digit: digit, eventID: eventID, time: now) : nil
        return FretEntryUpdate(fret: digit, startsNewEntry: true)
    }

    public mutating func reset() {
        pending = nil
    }
}
