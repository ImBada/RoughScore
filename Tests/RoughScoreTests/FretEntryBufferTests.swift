import Foundation
import RoughScoreCore
import Testing

struct FretEntryBufferTests {
    @Test func singleDigitsReplaceTheFret() {
        let eventID = UUID()
        var buffer = FretEntryBuffer()
        for digit in [0, 3, 4, 5, 6, 7, 8, 9, 0] {
            #expect(buffer.push(digit: digit, eventID: eventID, now: 1) ==
                    FretEntryUpdate(fret: digit, startsNewEntry: true))
        }
    }

    @Test func twoDigitFretsShareOneEdit() {
        for fret in [10, 12, 20, 24] {
            let eventID = UUID()
            var buffer = FretEntryBuffer()
            #expect(buffer.push(digit: fret / 10, eventID: eventID, now: 10) ==
                    FretEntryUpdate(fret: fret / 10, startsNewEntry: true))
            #expect(buffer.push(digit: fret % 10, eventID: eventID, now: 10.4) ==
                    FretEntryUpdate(fret: fret, startsNewEntry: false))
        }
    }

    @Test func invalidTwoDigitFretsResetTheEntry() {
        let eventID = UUID()
        for digit in 5...9 {
            var buffer = FretEntryBuffer()
            _ = buffer.push(digit: 2, eventID: eventID, now: 1)
            #expect(buffer.push(digit: digit, eventID: eventID, now: 1.2) == nil)
            #expect(buffer.push(digit: 4, eventID: eventID, now: 1.3) ==
                    FretEntryUpdate(fret: 4, startsNewEntry: true))
        }
    }

    @Test func timeoutStartsAReplacement() {
        let eventID = UUID()
        var buffer = FretEntryBuffer()
        _ = buffer.push(digit: 1, eventID: eventID, now: 1)
        #expect(buffer.push(digit: 2, eventID: eventID, now: 2) ==
                FretEntryUpdate(fret: 2, startsNewEntry: true))
        #expect(buffer.push(digit: 4, eventID: eventID, now: 2.1) ==
                FretEntryUpdate(fret: 24, startsNewEntry: false))
    }

    @Test func changingNotesStartsAReplacement() {
        let firstID = UUID(), secondID = UUID()
        var buffer = FretEntryBuffer()
        _ = buffer.push(digit: 1, eventID: firstID, now: 1)
        #expect(buffer.push(digit: 2, eventID: secondID, now: 1.2) ==
                FretEntryUpdate(fret: 2, startsNewEntry: true))
        #expect(buffer.push(digit: 0, eventID: secondID, now: 1.3) ==
                FretEntryUpdate(fret: 20, startsNewEntry: false))
    }

    @Test func explicitResetDiscardsTheLeadingDigit() {
        let eventID = UUID()
        var buffer = FretEntryBuffer()
        _ = buffer.push(digit: 1, eventID: eventID, now: 1)
        buffer.reset()
        #expect(buffer.push(digit: 2, eventID: eventID, now: 1.2) ==
                FretEntryUpdate(fret: 2, startsNewEntry: true))
    }

    @Test func aCompletedFretCannotGrowToThreeDigits() {
        let eventID = UUID()
        var buffer = FretEntryBuffer()
        _ = buffer.push(digit: 1, eventID: eventID, now: 1)
        _ = buffer.push(digit: 2, eventID: eventID, now: 1.1)
        #expect(buffer.push(digit: 1, eventID: eventID, now: 1.2) ==
                FretEntryUpdate(fret: 1, startsNewEntry: true))
        #expect(buffer.push(digit: 0, eventID: eventID, now: 1.3) ==
                FretEntryUpdate(fret: 10, startsNewEntry: false))
    }

    @Test func groupingWindowIncludesItsBoundary() {
        let eventID = UUID()
        var buffer = FretEntryBuffer()
        _ = buffer.push(digit: 1, eventID: eventID, now: 0)
        #expect(buffer.push(digit: 0, eventID: eventID, now: 0.9) ==
                FretEntryUpdate(fret: 10, startsNewEntry: false))
    }

    @Test func invalidInputIsRejectedAndClearsTheBuffer() {
        let eventID = UUID()
        for (digit, time) in [(-1, 1.1), (10, 1.1), (2, Double.nan), (2, Double.infinity)] {
            var buffer = FretEntryBuffer()
            _ = buffer.push(digit: 1, eventID: eventID, now: 1)
            #expect(buffer.push(digit: digit, eventID: eventID, now: time) == nil)
            #expect(buffer.push(digit: 4, eventID: eventID, now: 1.2) ==
                    FretEntryUpdate(fret: 4, startsNewEntry: true))
        }
    }

    @Test func aClockMovingBackwardStartsAReplacement() {
        let eventID = UUID()
        var buffer = FretEntryBuffer()
        _ = buffer.push(digit: 1, eventID: eventID, now: 2)
        #expect(buffer.push(digit: 2, eventID: eventID, now: 1) ==
                FretEntryUpdate(fret: 2, startsNewEntry: true))
    }
}
