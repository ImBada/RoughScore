import Foundation
import RoughScoreCore
import Testing

struct FingeringResolverTests {
    private func positions(_ result: FingeringResolution) -> [String] {
        result.candidates.map { "\($0.string)/\($0.fret)" }
    }

    @Test func standardPitchHasExactlySixPositionsAndNoWorkflowRequirement() {
        let project = ScoreProject()
        let result = FingeringResolver.resolve(midi: 64, project: project)
        #expect(positions(result) == ["1/0", "2/5", "3/9", "4/14", "5/19", "6/24"])
        #expect(result.candidates.allSatisfy {
            $0.preferredFretDistance == nil && $0.neighborFretDistance == 0 && $0.neighborStringDistance == 0
        })
        #expect(FingeringResolver.resolve(midi: 0, project: project) == .resolved([]))
        #expect(FingeringResolver.resolve(midi: 127, project: project) == .resolved([]))
    }

    @Test func dropDCapoOpenAndCustomStringOrderAreNumerical() {
        var project = ScoreProject()
        project.tuning = ["labels", "do", "not", "control", "numeric", "pitch"]
        project.tuningDefinition = TuningDefinition(openMIDIPitches: [64, 59, 55, 50, 45, 38], capo: 2)
        #expect(positions(FingeringResolver.resolve(midi: 40, project: project)) == ["6/0"])
        #expect(project.soundingMIDI(string: 6, fret: 0) == 40)
        project.tuningDefinition = TuningDefinition(openMIDIPitches: [38, 67, 40, 61, 55, 50], capo: 2)
        #expect(positions(FingeringResolver.resolve(midi: 40, project: project)) == ["1/0"])
        #expect(positions(FingeringResolver.resolve(midi: 42, project: project)) == ["3/0", "1/2"])
    }

    @Test func exhaustiveGeneratedTuningsMatchIndependentEquationForEveryMIDI() {
        var definitions = [TuningDefinition(), TuningDefinition(openMIDIPitches: [64, 59, 55, 50, 45, 38], capo: 2)]
        for capo in 0...24 {
            for seed in 0..<12 {
                let opens = (0..<6).map { (seed * 29 + $0 * 37) % (128 - capo) }
                definitions.append(TuningDefinition(openMIDIPitches: opens, capo: capo))
            }
            definitions.append(TuningDefinition(openMIDIPitches: [0, 127 - capo, 0, 127 - capo, 1, 126 - capo], capo: capo))
        }
        for definition in definitions {
            var project = ScoreProject()
            project.tuningDefinition = definition
            for midi in 0...127 {
                var expected: Set<String> = []
                // Independent forward equation, wide arithmetic, all 150 physical string/fret pairs.
                for stringIndex in 0..<6 {
                    for relativeFret in 0...24 {
                        let pitch = Int64(definition.openMIDIPitches[stringIndex]) + Int64(definition.capo) + Int64(relativeFret)
                        if pitch == Int64(midi) { expected.insert("\(stringIndex + 1)/\(relativeFret)") }
                    }
                }
                let result = FingeringResolver.resolve(midi: midi, project: project)
                guard case .resolved = result else { Issue.record("Valid generated tuning was rejected"); continue }
                let actual = positions(result)
                #expect(Set(actual) == expected)
                #expect(actual.count == expected.count)
                #expect(result.candidates.allSatisfy {
                    (0...24).contains($0.fret) && project.soundingMIDI(string: $0.string, fret: $0.fret) == midi
                })
            }
        }
    }

    @Test func pitchAndTuningRejectHostileIntegersWithoutOverflow() {
        let project = ScoreProject()
        for midi in [Int.min, -1, 128, Int.max] {
            #expect(FingeringResolver.resolve(midi: midi, project: project) == .invalidPitch)
        }
        var definitions = [TuningDefinition(openMIDIPitches: []), TuningDefinition(openMIDIPitches: [64]),
                           TuningDefinition(openMIDIPitches: Array(repeating: 40, count: 7))]
        for bad in [Int.min, -1, 128, Int.max] {
            definitions.append(TuningDefinition(openMIDIPitches: [bad, 59, 55, 50, 45, 40]))
        }
        for capo in [Int.min, -1, 25, Int.max] { definitions.append(TuningDefinition(capo: capo)) }
        definitions.append(TuningDefinition(openMIDIPitches: [127, 59, 55, 50, 45, 40], capo: 1))
        for version in [Int.min, 0, 2, Int.max] {
            var definition = TuningDefinition(); definition.version = version; definitions.append(definition)
        }
        for definition in definitions {
            var badProject = project; badProject.tuningDefinition = definition
            #expect(FingeringResolver.resolve(midi: 64, project: badProject) == .invalidTuning)
        }
    }

    @Test func legacyFallbackRequiresExactLabelsAndNeverInfersOctaves() {
        for labels in [["E", "B", "G", "D", "A", "D"], ["e", "B", "G", "D", "A", "E"],
                       ["E4", "B3", "G3", "D3", "A2", "E2"], [], ["E", "B", "G", "D", "A", " E"]] {
            var project = ScoreProject(); project.tuning = labels
            #expect(FingeringResolver.resolve(midi: 64, project: project) == .unresolvedTuning)
        }
    }

    @Test func extremeAllowedMIDIsAndCaposRemainPlayableOnlyWithinMIDIBounds() {
        var project = ScoreProject()
        project.tuningDefinition = TuningDefinition(openMIDIPitches: Array(repeating: 0, count: 6))
        #expect(positions(FingeringResolver.resolve(midi: 0, project: project)) == (1...6).map { "\($0)/0" })
        project.tuningDefinition = TuningDefinition(openMIDIPitches: Array(repeating: 103, count: 6), capo: 24)
        #expect(positions(FingeringResolver.resolve(midi: 127, project: project)) == (1...6).map { "\($0)/0" })
        #expect(FingeringResolver.resolve(midi: 126, project: project) == .resolved([]))
        project.tuningDefinition = TuningDefinition(openMIDIPitches: Array(repeating: 79, count: 6), capo: 24)
        #expect(positions(FingeringResolver.resolve(midi: 127, project: project)) == (1...6).map { "\($0)/24" })
        project.tuningDefinition = TuningDefinition(openMIDIPitches: Array(repeating: 127, count: 6))
        #expect(FingeringResolver.resolve(midi: 126, project: project) == .resolved([]))
    }

    @Test func preferenceAndBothStrictNeighborsAffectAdvisoryRank() {
        let project = ScoreProject(events: [TabEvent(time: 2, lane: .left, string: 3, fret: 8),
                                             TabEvent(time: 8, lane: .left, string: 3, fret: 10)])
        let context = FingeringContext(lane: .left, time: 5)
        let ranked = FingeringResolver.resolve(midi: 64, project: project, context: context)
        #expect(positions(ranked) == ["3/9", "2/5", "4/14", "1/0", "5/19", "6/24"])
        #expect(ranked.candidates.first?.neighborFretDistance == 2)
        #expect(ranked.candidates.first?.neighborStringDistance == 0)
        let preferred = FingeringResolver.resolve(midi: 64, project: project, preferredFret: 19, context: context)
        #expect(positions(preferred).first == "5/19")
        #expect(preferred.candidates.first?.preferredFretDistance == 0)
        #expect(positions(FingeringResolver.resolve(midi: 64, project: ScoreProject(), preferredFret: 10)).first == "3/9")
        #expect(positions(FingeringResolver.resolve(midi: 64, project: project, preferredFret: 0, context: context)).first == "1/0")
        #expect(positions(FingeringResolver.resolve(midi: 64, project: project, preferredFret: 24)).first == "6/24")
    }

    @Test func unknownExcludedCoincidentAndDistantNotesDoNotReplaceNeighbors() {
        let edited = TabEvent(time: 5, lane: .left, string: 6, fret: 24)
        let base = ScoreProject(events: [TabEvent(time: 2, lane: .left, string: 3, fret: 8),
                                         TabEvent(time: 8, lane: .left, string: 3, fret: 10)])
        let context = FingeringContext(lane: .left, time: 5, excludingEventID: edited.id)
        let expected = FingeringResolver.resolve(midi: 64, project: base, context: context)
        var expanded = base
        var excluded = edited; excluded.time = 4.9; excluded.string = Int.max; excluded.fret = Int.min
        expanded.events += [excluded, TabEvent(time: 5, lane: .left, string: 6, fret: 24),
                            TabEvent(time: 4.99, lane: .left, string: 6), TabEvent(time: 5.01, lane: .left, string: 1),
                            TabEvent(time: 1, lane: .left, string: 1, fret: 0),
                            TabEvent(time: 9, lane: .left, string: 6, fret: 24)]
        #expect(FingeringResolver.resolve(midi: 64, project: expanded, context: context) == expected)
        let noExclusion = FingeringContext(lane: .left, time: 5)
        #expect(FingeringResolver.resolve(midi: 64, project: expanded, context: noExclusion) == .invalidContext)
    }

    @Test func nearestTimeGroupsUseAllKnownNotesAndPermutationCannotChangeRanking() {
        let events = [TabEvent(time: 2, lane: .left, string: 6, fret: 20),
                      TabEvent(time: 2, lane: .left, string: 5, fret: 18),
                      TabEvent(time: 8, lane: .left, string: 6, fret: 20),
                      TabEvent(time: 2, lane: .left, string: 1)]
        let context = FingeringContext(lane: .left, time: 5)
        let expected = FingeringResolver.resolve(midi: 64, project: ScoreProject(events: events), context: context)
        #expect(positions(expected).first == "5/19")
        #expect(expected.candidates.first?.neighborFretDistance == 3)
        #expect(expected.candidates.first?.neighborStringDistance == 2)
        for a in events.indices {
            for b in events.indices where b != a {
                for c in events.indices where c != a && c != b {
                    let d = events.indices.first { $0 != a && $0 != b && $0 != c }!
                    let project = ScoreProject(events: [events[a], events[b], events[c], events[d]])
                    #expect(FingeringResolver.resolve(midi: 64, project: project, context: context) == expected)
                }
            }
        }
    }

    @Test func previousOnlyNextOnlyAndStableTieBreaksAreSpecified() {
        let context = FingeringContext(lane: .right, time: 5)
        for time in [2.0, 8.0] {
            var project = ScoreProject(events: [TabEvent(time: time, lane: .right, string: 4, fret: 4)])
            project.tuningDefinition = TuningDefinition(openMIDIPitches: Array(repeating: 60, count: 6))
            #expect(positions(FingeringResolver.resolve(midi: 64, project: project, context: context)) ==
                    ["4/4", "3/4", "5/4", "2/4", "6/4", "1/4"])
        }
        let tied = ScoreProject(events: [TabEvent(time: 2, lane: .right, string: 2, fret: 5),
                                          TabEvent(time: 8, lane: .right, string: 4, fret: 14)])
        #expect(positions(FingeringResolver.resolve(midi: 64, project: tied, context: context)).prefix(3) ==
                ["2/5", "3/9", "4/14"])
        let coincidentOnly = ScoreProject(events: [TabEvent(time: 5, lane: .right, string: 6, fret: 24)])
        #expect(FingeringResolver.resolve(midi: 64, project: coincidentOnly, context: context) ==
                FingeringResolver.resolve(midi: 64, project: ScoreProject()))
    }

    @Test func oppositeLaneChangesEvenMalformedEventsCannotAffectRank() {
        let context = FingeringContext(lane: .left, time: 5)
        var project = ScoreProject(events: [TabEvent(time: 2, lane: .left, string: 3, fret: 9)])
        let expected = FingeringResolver.resolve(midi: 64, project: project, context: context)
        let invalid = TabEvent(time: .nan, lane: .right, string: Int.max, fret: Int.min)
        project.events += [invalid, invalid, TabEvent(time: 4.9, lane: .right, string: 6, fret: 24)]
        #expect(FingeringResolver.resolve(midi: 64, project: project, context: context) == expected)
        project.events.reverse()
        #expect(FingeringResolver.resolve(midi: 64, project: project, context: context) == expected)
    }

    @Test func invalidPreferenceAndRelevantContextAreExplicitlyRejected() {
        let project = ScoreProject()
        for preference in [Int.min, -1, 25, Int.max] {
            #expect(FingeringResolver.resolve(midi: 64, project: project, preferredFret: preference) == .invalidPreference)
        }
        for time in [-1.0, .nan, .infinity, -.infinity, project.duration] {
            #expect(FingeringResolver.resolve(midi: 64, project: project,
                                              context: FingeringContext(lane: .left, time: time)) == .invalidContext)
        }
        for duration in [0.0, -1, .nan, .infinity, 86_401] {
            var invalid = project; invalid.duration = duration
            #expect(FingeringResolver.resolve(midi: 64, project: invalid,
                                              context: FingeringContext(lane: .left, time: 0)) == .invalidContext)
        }
        for event in [TabEvent(time: .nan, lane: .left, string: 1),
                      TabEvent(time: 24, lane: .left, string: 1),
                      TabEvent(time: -1, lane: .left, string: 1),
                      TabEvent(time: 1, lane: .left, string: Int.min),
                      TabEvent(time: 1, lane: .left, string: 7),
                      TabEvent(time: 1, lane: .left, string: 1, fret: Int.max),
                      TabEvent(time: 1, lane: .left, string: 1, fret: -1)] {
            let invalid = ScoreProject(events: [event])
            #expect(FingeringResolver.resolve(midi: 64, project: invalid,
                                              context: FingeringContext(lane: .left, time: 5)) == .invalidContext)
        }
        let duplicate = TabEvent(time: 1, lane: .left, string: 1, fret: 2)
        #expect(FingeringResolver.resolve(midi: 64, project: ScoreProject(events: [duplicate, duplicate]),
                                          context: FingeringContext(lane: .left, time: 5)) == .invalidContext)
    }

    @Test func projectAndEncodedBytesRemainUnchanged() throws {
        let edited = TabEvent(time: 5.123456789, lane: .left, string: 6, length: nil, tentative: true, memo: "수동 · unknown")
        var project = ScoreProject(title: "exact annotations", duration: 30, events: [edited,
            TabEvent(time: 2.789, lane: .left, string: 3, fret: 8, length: .eighth, memo: "neighbor"),
            TabEvent(time: 6.543, lane: .right, string: 2, fret: 7, memo: "other lane")],
            analyses: ["left": AnalysisSummary(beats: [1.234], sections: [TimeSpan(start: 0, end: 1)])])
        project.tuningDefinition = TuningDefinition(capo: 2)
        let original = project
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(project)
        let context = FingeringContext(lane: edited.lane, time: edited.time, excludingEventID: edited.id)
        for midi in 0...127 { _ = FingeringResolver.resolve(midi: midi, project: project, preferredFret: 9, context: context) }
        #expect(project == original)
        #expect(try encoder.encode(project) == bytes)
        #expect(project.events[0].fret == nil && project.events[0].length == nil)
        #expect(project.events.map(\.id) == original.events.map(\.id))
    }
}
