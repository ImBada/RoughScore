import Foundation
import RoughScoreCore
import Testing

struct BulkEditTests {
    private static let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private static let unrelated = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    private static let absent = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!

    private func riff() -> ScoreProject {
        // Intentionally unsorted storage, simultaneous chord notes, both lanes,
        // unknown fret/rhythm and a Korean memo: timing is authored independently.
        var project = ScoreProject(title: "수동 원본", audioPath: "/fixture/generated.wav", duration: 12, events: [
            TabEvent(id: Self.c, time: 3.75, lane: .right, string: 2, fret: 8, length: .eighth, tentative: true, memo: "다시 듣기 🎸 e\u{301}"),
            TabEvent(id: Self.a, time: 3.125, lane: .left, string: 6, fret: 0, memo: "low E"),
            TabEvent(id: Self.b, time: 3.125, lane: .left, string: 4, fret: nil, length: nil, tentative: true, memo: "음고 모름"),
            TabEvent(id: Self.unrelated, time: 8, lane: .right, string: 1, fret: 24, length: .quarter, memo: "untouched")
        ], analyses: ["left": AnalysisSummary(bpm: 113, key: "C", beats: [1, 2.25], bars: [0, 7], sections: [TimeSpan(start: 1, end: 5)])])
        project.tuning = ["D", "A", "F", "C", "G", "D"]
        // Authored metadata fixtures only; no source audio or inference is loaded.
        let identity = AudioContentIdentity(sha256: String(repeating: "a", count: 64),
                                            channelCount: 2, sampleRate: 48_000, frameCount: 576_000)
        let original = AudioAsset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000061")!,
                                  reference: AudioReference(path: "/fixture/generated.wav"), identity: identity)
        let stem = AudioAsset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000062")!,
                              role: .importedGuitarStem,
                              reference: AudioReference(kind: .contained, path: "audio/authored-metadata-only.wav"),
                              originalTimeOffset: -0.25)
        project.assets = [original, stem]
        project.tuningDefinition = TuningDefinition(openMIDIPitches: [62, 57, 53, 48, 43, 38], capo: 2)
        project.analyses["left"]?.provenance = AnalysisProvenance(assetID: original.id, identity: identity,
            channel: "left", analyzerVersion: "authored-unit-metadata-v1", settings: "no-inference")
        return project
    }

    private func selected() throws -> TabSelection {
        try TabSelection(ids: [Self.a, Self.b, Self.c], primaryID: Self.b)
    }

    private func expectMetadata(_ actual: ScoreProject, equals original: ScoreProject) {
        #expect(actual.version == original.version)
        #expect(actual.title == original.title)
        #expect(actual.audioPath == original.audioPath)
        #expect(actual.duration == original.duration)
        #expect(actual.tuning == original.tuning)
        #expect(actual.analyses == original.analyses)
        var withoutEventEdits = actual
        withoutEventEdits.events = original.events
        #expect(withoutEventEdits == original) // Includes any current schema metadata.
    }

    @Test func mixedRiffClipboardRoundTripAndFreshPaste() throws {
        let original = riff()
        let fragment = try TabFragment.copy(from: original, selection: selected())
        #expect(fragment.events.map(\.relativeTime) == [0.625, 0, 0])
        #expect(fragment.primaryIndex == 2)
        let decoded = try TabFragment.decode(fragment.encoded())
        #expect(decoded == fragment)
        let result = try TabEditCommand.paste(fragment: decoded, at: 5).apply(to: original)
        #expect(result.changed)
        #expect(result.affectedIDs.count == 3)
        #expect(result.project.events.count == 7)
        #expect(Array(result.project.events.prefix(4)) == original.events)
        let pasted = Array(result.project.events.suffix(3))
        #expect(pasted.map(\.time) == [5.625, 5, 5])
        #expect(pasted.map(\.lane) == [.right, .left, .left])
        #expect(Set(pasted.map(\.id)).isDisjoint(with: Set(original.events.map(\.id))))
        #expect(Set(pasted.map(\.id)).count == 3)
        for (source, target) in zip(original.events.prefix(3), pasted) {
            #expect(source.string == target.string && source.fret == target.fret)
            #expect(source.length == target.length && source.tentative == target.tentative && source.memo == target.memo)
            #expect(source.memo.utf8.elementsEqual(target.memo.utf8))
        }
        #expect(result.pastedSelection?.primaryID == pasted[2].id)
        expectMetadata(result.project, equals: original)
        #expect(original == riff()) // The source value is still byte-for-byte authored.
    }

    @Test func explicitLaneTransferIsTheOnlyLaneMapping() throws {
        let project = riff()
        let fragment = try TabFragment.copy(from: project, selection: selected())
        let mapped = try TabEditCommand.paste(fragment: fragment, at: 5, targetLane: .right).apply(to: project)
        #expect(mapped.project.events.suffix(3).allSatisfy { $0.lane == .right })
        #expect(Array(mapped.project.events.prefix(4)) == project.events)
        let moved = try TabEditCommand.move(selection: selected(), timeDelta: 1, targetLane: .left).apply(to: project)
        #expect(moved.project.events.prefix(3).allSatisfy { $0.lane == .left })
        #expect(moved.project.events.last == project.events.last)
    }

    @Test func halfOpenRangeKeepsLeadingSilenceAndDistinctChordIDs() throws {
        let project = riff()
        let range = try TabSelection.range(in: project, lane: .left, from: 3, to: 3.75, primaryID: Self.a)
        #expect(range.ids == [Self.a, Self.b])
        let resolved = try range.resolved(in: project)
        #expect(resolved.map(\.id) == [Self.a, Self.b])
        let fragment = try TabFragment.copy(from: project, selection: range)
        #expect(fragment.events.map(\.relativeTime) == [0.125, 0.125])
        let pasted = try TabEditCommand.paste(fragment: fragment, at: 6).apply(to: project)
        #expect(pasted.project.events.suffix(2).map(\.time) == [6.125, 6.125])
        #expect(pasted.affectedIDs.count == 2)
        let excluding = try TabSelection.range(in: project, lane: .right, from: 0, to: 3.75)
        #expect(excluding.ids.isEmpty) // The R note at the end boundary is excluded.
        let including = try TabSelection.range(in: project, lane: .right, from: 3.75, to: 12)
        #expect(including.ids == [Self.c, Self.unrelated])
    }

    @Test func selectionIsStableSnapshotAndUnknownIDsReject() throws {
        var project = riff()
        let range = try TabSelection.range(in: project, lane: .left, from: 3, to: 4)
        let later = TabEvent(time: 3.5, lane: .left, string: 1)
        project.events.append(later)
        #expect(try range.resolved(in: project).map(\.id) == [Self.a, Self.b])
        project.events.removeAll { $0.id == Self.b }
        #expect(throws: TabEditError.staleSelection(Self.b)) { try range.resolved(in: project) }
        let stale = try TabSelection(ids: [Self.a, Self.absent], primaryID: Self.a)
        #expect(throws: TabEditError.staleSelection(Self.absent)) { try TabEditCommand.delete(selection: stale).apply(to: riff()) }
        #expect(throws: TabEditError.staleSelection(Self.absent)) { try TabFragment.copy(from: riff(), selection: stale) }
        #expect(throws: TabEditError.invalidSelection) { try TabSelection(ids: [Self.a], primaryID: Self.absent) }
    }

    @Test func groupMoveRetainsIDsIntervalsMetadataAndUnrelatedNote() throws {
        let project = riff()
        let moved = try TabEditCommand.move(selection: selected(), timeDelta: 2.25).apply(to: project)
        #expect(moved.changed && moved.affectedIDs == [Self.a, Self.b, Self.c])
        #expect(moved.project.events.map(\.time) == [6, 5.375, 5.375, 8])
        #expect(moved.project.events.map(\.id) == project.events.map(\.id))
        #expect(moved.project.events[0].time - moved.project.events[1].time == 0.625)
        #expect(moved.project.events[1].time == moved.project.events[2].time)
        for (source, target) in zip(project.events.prefix(3), moved.project.events.prefix(3)) {
            var expected = source; expected.time += 2.25
            #expect(target == expected)
        }
        #expect(moved.project.events.last == project.events.last)
        expectMetadata(moved.project, equals: project)
    }

    @Test func moveTimeAndStringBoundsRejectWholeOperation() throws {
        let project = riff(), selection = try selected()
        for offset in [-4.0, 8.875, Double.infinity, .nan] {
            #expect(throws: (any Error).self) { try TabEditCommand.move(selection: selection, timeDelta: offset).apply(to: project) }
            #expect(project == riff())
        }
        for delta in [1, -4, Int.max, Int.min] {
            #expect(throws: TabEditError.outOfBounds) { try TabEditCommand.move(selection: selection, timeDelta: 0.25, stringDelta: delta).apply(to: project) }
            #expect(project == riff())
        }
        let one = try TabSelection(ids: [Self.c])
        let shifted = try TabEditCommand.move(selection: one, timeDelta: 0, stringDelta: 1).apply(to: project)
        #expect(shifted.project.events[0].string == 3)
        #expect(shifted.project.events[0].time == project.events[0].time)
    }

    @Test func deleteAndOptionalLengthAreAtomicPureChanges() throws {
        let project = riff(), selection = try selected()
        let removed = try TabEditCommand.delete(selection: selection).apply(to: project)
        #expect(removed.project.events == [project.events[3]])
        #expect(removed.affectedIDs == selection.ids)
        expectMetadata(removed.project, equals: project)
        let set = try TabEditCommand.setLength(selection: selection, length: .sixteenth).apply(to: project)
        #expect(set.project.events.prefix(3).allSatisfy { $0.length == .sixteenth })
        #expect(set.project.events.last == project.events.last)
        let cleared = try TabEditCommand.setLength(selection: selection, length: nil).apply(to: set.project)
        #expect(cleared.project.events.prefix(3).allSatisfy { $0.length == nil })
        #expect(cleared.project.events[1].fret == 0 && cleared.project.events[2].fret == nil)
        expectMetadata(cleared.project, equals: project)
        #expect(project == riff())
    }

    @Test func tentativeEditPreservesAllOtherFields() throws {
        let project = riff()
        let edited = try TabEditCommand.setTentative(selection: selected(), value: false).apply(to: project)
        #expect(edited.affectedIDs == [Self.b, Self.c])
        for (before, after) in zip(project.events, edited.project.events) {
            var expected = before
            if before.id != Self.unrelated { expected.tentative = false }
            #expect(after == expected)
        }
    }

    @Test func noOpsReportNoChangeAndPreserveExactOriginalValue() throws {
        let project = riff(), selection = try selected(), empty = try TabSelection()
        let unknownRhythm = try TabSelection(ids: [Self.a, Self.b])
        let commands: [TabEditCommand] = [
            .move(selection: selection, timeDelta: 0), .delete(selection: empty),
            .setLength(selection: unknownRhythm, length: nil),
            .setTentative(selection: try TabSelection(ids: [Self.b, Self.c]), value: true),
            .paste(fragment: try TabFragment(events: []), at: 0)
        ]
        for command in commands {
            let result = try command.apply(to: project)
            #expect(!result.changed && result.affectedIDs.isEmpty && result.project == project)
        }
        let sameLength = try TabSelection(ids: [Self.c])
        #expect(try !TabEditCommand.setLength(selection: sameLength, length: .eighth).apply(to: project).changed)
        let stale = try TabSelection(ids: [Self.absent])
        #expect(throws: TabEditError.staleSelection(Self.absent)) { try TabEditCommand.move(selection: stale, timeDelta: 0).apply(to: project) }
        var signedZero = project; signedZero.events[0].time = -0.0
        let preserved = try TabEditCommand.move(selection: sameLength, timeDelta: 0).apply(to: signedZero)
        #expect(!preserved.changed && preserved.project.events[0].time.bitPattern == (-0.0).bitPattern)
    }

    @Test func pasteBoundsAndUUIDCollisionRejectWithoutPartialMutation() throws {
        let project = riff(), fragment = try TabFragment.copy(from: project, selection: selected())
        for cursor in [-1.0, 11.375, 12, .infinity, .nan] {
            #expect(throws: TabEditError.outOfBounds) { try TabEditCommand.paste(fragment: fragment, at: cursor).apply(to: project) }
            #expect(project == riff())
        }
        #expect(throws: TabEditError.generatedIDCollision) {
            try TabEditCommand.paste(fragment: fragment, at: 4).apply(to: project, makeID: { Self.a })
        }
        let newID = UUID()
        #expect(throws: TabEditError.generatedIDCollision) {
            try TabEditCommand.paste(fragment: fragment, at: 4).apply(to: project, makeID: { newID })
        }
        #expect(project == riff())
    }

    @Test func tinyPositiveDurationsUseEndExclusiveBoundsWithoutEpsilonClamp() throws {
        for duration in [Double.leastNonzeroMagnitude, 0.000_001, 0.1] {
            let event = TabEvent(time: 0, lane: .left, string: 1)
            let project = ScoreProject(duration: duration, events: [event])
            let selection = try TabSelection.range(in: project, lane: .left, from: 0, to: duration)
            #expect(selection.ids == [event.id])
            let fragment = try TabFragment.copy(from: project, selection: selection)
            let pasted = try TabEditCommand.paste(fragment: fragment, at: 0).apply(to: project)
            #expect(pasted.project.events.count == 2 && pasted.project.events[1].time == 0)
            #expect(throws: TabEditError.outOfBounds) { try TabEditCommand.move(selection: selection, timeDelta: duration).apply(to: project) }
            if duration.nextDown > 0 {
                let last = try TabEditCommand.move(selection: selection, timeDelta: duration.nextDown).apply(to: project)
                #expect(last.project.events[0].time == duration.nextDown)
            }
        }
    }

    @Test func rangeAndCopyOriginFailuresAreExplicit() throws {
        let project = riff()
        for (start, end) in [(-1.0, 2.0), (4, 3), (0, 13), (Double.nan, 5), (0, .infinity)] {
            #expect(throws: TabEditError.invalidRange) { try TabSelection.range(in: project, lane: .left, from: start, to: end) }
        }
        let selection = try TabSelection.range(in: project, lane: .left, from: 3, to: 4)
        let moved = try TabEditCommand.move(selection: selection, timeDelta: -1).apply(to: project)
        #expect(throws: TabEditError.invalidCopyOrigin) { try TabFragment.copy(from: moved.project, selection: selection) }
        let refreshed = try TabSelection(ids: selection.ids, primaryID: selection.primaryID)
        #expect(try TabFragment.copy(from: moved.project, selection: refreshed).events.allSatisfy { $0.relativeTime == 0 })
    }

    @Test func floatingPointCollapseRejectsInsteadOfInventingCoincidence() throws {
        let events = [TabEvent(time: 0, lane: .left, string: 1), TabEvent(time: 1e-12, lane: .right, string: 2)]
        let project = ScoreProject(duration: 86_400, events: events)
        let selection = try TabSelection(ids: Set(events.map(\.id)))
        #expect(throws: TabEditError.unrepresentableTiming) { try TabEditCommand.move(selection: selection, timeDelta: 80_000).apply(to: project) }
        let fragment = try TabFragment.copy(from: project, selection: selection)
        #expect(throws: TabEditError.unrepresentableTiming) { try TabEditCommand.paste(fragment: fragment, at: 80_000).apply(to: project) }
    }

    @Test func legacyV1AndCurrentProjectsInteroperateAndFutureProjectIsRejected() throws {
        let original = riff()
        let decoded = try JSONDecoder().decode(ScoreProject.self, from: JSONEncoder().encode(original)).validated()
        #expect(decoded == original)
        let fragment = try TabFragment.copy(from: decoded, selection: selected())
        let result = try TabEditCommand.paste(fragment: fragment, at: 5).apply(to: decoded)
        #expect(result.project.version == decoded.version)
        expectMetadata(result.project, equals: decoded)
        let legacy = Data("""
        {"version":1,"title":"legacy v1","duration":10,"tuning":["E","B","G","D","A","E"],"events":[{"id":"00000000-0000-0000-0000-000000000001","time":0.125,"lane":"left","string":6,"fret":null,"length":null,"tentative":true,"memo":"legacy unknown"}],"analyses":{}}
        """.utf8)
        let v1 = try JSONDecoder().decode(ScoreProject.self, from: legacy).validated()
        let selection = try TabSelection(ids: [Self.a])
        let copied = try TabFragment.copy(from: v1, selection: selection)
        let pasted = try TabEditCommand.paste(fragment: copied, at: 2).apply(to: v1)
        #expect(pasted.project.events[1].time == 2 && pasted.project.events[1].fret == nil && pasted.project.events[1].length == nil)
        #expect(pasted.project.events[1].memo == "legacy unknown" && pasted.project.events[1].tentative)
        expectMetadata(pasted.project, equals: v1)
        var future = original; future.version = Int.max
        #expect(throws: ProjectError.unsupportedVersion) { try TabEditCommand.delete(selection: selected()).apply(to: future) }
        var invalid = original; invalid.events.append(original.events[0])
        #expect(throws: ProjectError.invalidData) { try TabEditCommand.delete(selection: selected()).apply(to: invalid) }
    }

    @Test func malformedClipboardVersionsNumbersAndMetadataCannotBecomeUsableFragments() throws {
        let valid = try TabFragment.copy(from: riff(), selection: selected()).encoded()
        let base = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var payloads = [Data("not JSON".utf8), Data("null".utf8)]
        for version in [0, 2, Int.max] {
            var value = base; value["schemaVersion"] = version
            let data = try JSONSerialization.data(withJSONObject: value)
            #expect(throws: TabEditError.unsupportedFragmentVersion(version)) { try TabFragment.decode(data) }
        }
        for field in ["relativeTime", "string", "fret", "lane", "length", "tentative", "memo"] {
            var value = base
            var events = try #require(base["events"] as? [[String: Any]])
            switch field {
            case "relativeTime": events[0][field] = -0.5
            case "string": events[0][field] = 7
            case "fret": events[0][field] = 25
            case "lane": events[0][field] = "middle"
            case "length": events[0][field] = "mandatory-beat"
            case "tentative": events[0][field] = "yes"
            default: events[0][field] = 123
            }
            value["events"] = events
            payloads.append(try JSONSerialization.data(withJSONObject: value))
        }
        var badPrimary = base; badPrimary["primaryIndex"] = 99
        payloads.append(try JSONSerialization.data(withJSONObject: badPrimary))
        var noPrimary = base; noPrimary.removeValue(forKey: "primaryIndex")
        payloads.append(try JSONSerialization.data(withJSONObject: noPrimary))
        let nonfinite = String(data: valid, encoding: .utf8)!.replacingOccurrences(of: "0.625", with: "1e999")
        payloads.append(Data(nonfinite.utf8))
        for data in payloads { #expect(throws: (any Error).self) { try TabFragment.decode(data) } }
        let project = riff()
        #expect(project == riff())
    }

    @Test func typedFragmentsAndByteEventMemoLimitsAreEnforced() throws {
        for time in [-1.0, .nan, .infinity, 86_400, 86_401] {
            #expect(throws: TabEditError.invalidFragment) { try TabFragment(events: [.init(relativeTime: time, lane: .left, string: 1)]) }
        }
        #expect(throws: TabEditError.invalidFragment) { try TabFragment(events: [], primaryIndex: 0) }
        #expect(throws: TabEditError.clipboardTooLarge) { try TabFragment.decode(Data(repeating: 32, count: TabFragment.maximumEncodedBytes + 1)) }
        let entry = TabFragment.Entry(relativeTime: 0, lane: .left, string: 1)
        #expect(throws: TabEditError.clipboardTooLarge) { try TabFragment(events: Array(repeating: entry, count: TabFragment.maximumEvents + 1)) }
        let oversizedMemo = TabFragment.Entry(relativeTime: 0, lane: .left, string: 1, memo: String(repeating: "한", count: 6000))
        #expect(throws: TabEditError.clipboardTooLarge) { try TabFragment(events: [oversizedMemo]) }
        let escapedMemo = TabFragment.Entry(relativeTime: 0, lane: .left, string: 1, memo: String(repeating: "\n", count: 16_000))
        #expect(throws: TabEditError.clipboardTooLarge) { try TabFragment(events: Array(repeating: escapedMemo, count: 40)) }
        // Decode count limits even when callers use Codable directly, not the
        // preferred byte-bounded entry point.
        let row: [String: Any] = ["relativeTime": 0, "lane": "left", "string": 1, "tentative": false, "memo": ""]
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "primaryIndex": 0, "events": Array(repeating: row, count: TabFragment.maximumEvents + 1)])
        #expect(throws: TabEditError.clipboardTooLarge) { try JSONDecoder().decode(TabFragment.self, from: data) }
    }
}
