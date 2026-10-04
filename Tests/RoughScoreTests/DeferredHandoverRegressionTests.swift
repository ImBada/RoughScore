// Regression probes from the independent deferred-handover review of a2f4d20.
import AVFoundation
import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

@MainActor
struct DeferredHandoverRegressionHarness {
    let helper = StemReviewHarness()
    func record(_ name: String, _ row: [String:Any]) throws { try helper.record("deferred-"+name,row) }
    func setup(duration: Double = 6) async throws -> (Workspace, StemReviewCapture, DeferredRegressionControl) {
        let o=try helper.fixture("deferred-original",duration:duration,rate:44100),s=try helper.fixture("deferred-stem",duration:duration,padding:0.25)
        let cap=StemReviewCapture(),control=DeferredRegressionControl();var service=helper.services(cap);let make=service.makePlayer
        service.makePlayer={url in DeferredRegressionPort(native:try make(url),url:url,control:control)}
        let w=Workspace(services:service)
        #expect(await w.loadAudio(at:o)?.value==true)
        let original=try #require(w.prepared);control.originalURLs=Set(ListeningSource.allCases.map{original.url(for:$0)})
        #expect(await w.attachStem(at:s,offset:-0.25)?.value==true)
        w.seek(1.7);w.togglePlayback();try await Task.sleep(for:.milliseconds(250))
        return (w,cap,control)
    }
    func failedRapidReversalKeepsActualOutgoingAudioUntilPendingEpoch() async throws {
        let (w,cap,control)=try await setup();defer{w.shutdown()}
        let original=try #require(cap.players[w.prepared!.url(for:.stereo)])
        #expect(w.switchAsset(.importedGuitarStem))
        let stem=try #require(cap.players[w.prepared!.url(for:.stereo)])
        let epoch=try #require(control.epochs[stem.graph.id])
        control.failOriginalPlay=true
        #expect(!w.switchAsset(.original))
        let clock=try #require(stem.graph.inputClockSnapshot())
        let remaining=epoch-stem.deviceCurrentTime
        try record("failed-rapid-reversal",["remainingUntilStemEpochSeconds":remaining,"stemInputFrames":clock.playerFrames.values.map{Int($0)},"originalIsPlaying":original.isPlaying,"originalNativeStereoGain":original.graph.nativeGains[.stereo]!,"stemNativeStereoGain":stem.graph.nativeGains[.stereo]!,"publishedPlaying":w.playing,"assetRole":String(describing:w.assetRole)])
        #expect(remaining > 0.015)
        #expect(original.isPlaying && original.graph.nativeGains[.stereo]==1,"Failure before pending Stem epoch must retain the actual audible Original graph and native gain")
    }
    func pendingRateChangePreservesCommonNativeOriginalTime() async throws {
        let (w,cap,_)=try await setup();defer{w.shutdown()}
        let old=try #require(cap.players[w.prepared!.url(for:.stereo)])
        #expect(w.switchAsset(.importedGuitarStem))
        let new=try #require(cap.players[w.prepared!.url(for:.stereo)])
        let before=try #require(old.graph.inputClockSnapshot())
        w.rate=0.5
        let oldRate=old.rate
        try await Task.sleep(for:.milliseconds(180))
        let after=try #require(new.graph.inputClockSnapshot())
        let delta=AVAudioTime.seconds(forHostTime:after.hostTime)-AVAudioTime.seconds(forHostTime:before.hostTime)
        let error=after.positions[.stereo]!-(before.positions[.stereo]!+delta*0.5)
        try record("pending-rate",["oldNativeRateAfterRequest":oldRate,"newNativeRate":new.rate,"commonTimeErrorSeconds":error,"oldPosition":before.positions[.stereo]!,"newPosition":after.positions[.stereo]!,"hostDelta":delta])
        #expect(oldRate==0.5,"The graph still supplying audio before epoch must apply the requested playback rate")
        #expect(abs(error)<=0.015,"Pending rate change must preserve native original-time clock within unchanged 15ms tolerance")
    }
    func offsetCommitDoesNotStopOutgoingStemBeforeOriginalEpoch() async throws {
        // Native VM setup can outlast the short EOF fixture. Keep this cutover fixture live;
        // the separate EOF probe still uses six seconds and the same clock assertions.
        let (w,cap,control)=try await setup(duration: 60);defer{w.shutdown()}
        #expect(w.switchAsset(.importedGuitarStem));try await Task.sleep(for:.milliseconds(150))
        let stem=try #require(cap.players[w.prepared!.url(for:.stereo)])
        #expect(stem.isPlaying)
        control.monitoredStem = stem.sharedClockID
        // The capture maps URLs to each native channel; select Original's stereo clock directly.
        control.originalPlayer = cap.players.first { control.originalURLs.contains($0.key) && $0.value.source == .stereo }?.value
        #expect(await w.setStemOffset(-0.5)?.value==true)
        let original=try #require(cap.players[w.prepared!.url(for:.stereo)])
        let epoch=try #require(control.epochs[original.graph.id]);let remaining=epoch-original.deviceCurrentTime
        let clock=try #require(original.graph.inputClockSnapshot())
        try record("offset-commit",["remainingUntilOriginalEpochSeconds":remaining,"originalInputFrames":clock.playerFrames.values.map{Int($0)},"outgoingStemIsPlaying":stem.isPlaying,"outgoingStemNativeGain":stem.graph.nativeGains[.stereo]!,"offset":w.project.stemAsset!.originalTimeOffset])
        #expect(control.earlyStemRetirements.isEmpty, "Offset Apply must not mute/pause/stop its audible Stem before Original's native epoch")
        if remaining > 0 {
            #expect(stem.isPlaying && stem.graph.nativeGains[.stereo]==1,"Offset publication must keep outgoing Stem alive until actual Original epoch")
        }
        try await Task.sleep(for: .seconds(max(0, epoch - original.deviceCurrentTime) + 0.05))
        let after = try #require(original.graph.inputClockSnapshot())
        #expect(original.isPlaying && after.playerFrames[.stereo, default: 0] > 0)
        #expect(!stem.isPlaying && stem.graph.nativeGains[.stereo] == 0)
    }
    func successfulRapidReversalKeepsAudibleClockAndDoesNotAdvanceFrozenPendingTime() async throws {
        let (w,cap,control)=try await setup();defer{w.shutdown()}
        let old=try #require(cap.players[w.prepared!.url(for:.stereo)]),before=try #require(old.graph.inputClockSnapshot())
        #expect(w.switchAsset(.importedGuitarStem));#expect(w.switchAsset(.original))
        let new=try #require(cap.players[w.prepared!.url(for:.stereo)]),epoch=try #require(control.epochs[new.graph.id])
        let clock=try #require(new.graph.inputClockSnapshot())
        try record("successful-rapid-reversal",["remainingUntilEpochSeconds":epoch-new.deviceCurrentTime,"nativeOriginalInputFrames":clock.playerFrames.values.map{Int($0)},"originalNativeGain":new.graph.nativeGains[.stereo]!,"oldPosition":before.positions[.stereo]!,"scheduledPosition":new.currentTime])
        #expect(clock.playerFrames[.stereo]! > 0,"Rapid reversal must not replace the actual audible clock with another future start leaving both assets unrendered")
    }
    func pauseBeforeHandoverEpochFreezesActualAudibleOriginalTime() async throws {
        let (w,cap,control)=try await setup();defer{w.shutdown()}
        let old=try #require(cap.players[w.prepared!.url(for:.stereo)])
        #expect(w.switchAsset(.importedGuitarStem))
        let incoming=try #require(cap.players[w.prepared!.url(for:.stereo)]),epoch=try #require(control.epochs[incoming.graph.id])
        let remaining=epoch-incoming.deviceCurrentTime
        w.togglePlayback()
        let error=w.cursor-old.currentTime
        try record("pending-pause",["remainingUntilEpochSeconds":remaining,"actualOutgoingPausedPosition":old.currentTime,"workspacePausedCursor":w.cursor,"skippedOriginalSeconds":error,"incomingPausedPosition":incoming.currentTime,"playing":w.playing])
        #expect(!w.playing && !old.isPlaying && !incoming.isPlaying)
        #expect(abs(error)<=0.015,"Pausing while outgoing audio still renders must freeze its actual original time, not the incoming future-epoch anchor")
    }
    func pendingSeekAndSourceChangesCancelOldEpochWithoutLateMuting() async throws {
        let (w,cap,_)=try await setup();defer{w.shutdown()}
        let old=try #require(cap.players[w.prepared!.url(for:.stereo)])
        #expect(w.switchAsset(.importedGuitarStem));w.switchSource(.left)
        w.seek(3.0);w.switchSource(.right)
        try await Task.sleep(for:.milliseconds(180))
        let p=try #require(cap.players[w.prepared!.url(for:.right)]),clock=try #require(p.graph.inputClockSnapshot())
        #expect(w.playing && p.isPlaying && !old.isPlaying)
        #expect(p.graph.nativeGains[.right]==1 && p.graph.nativeGains[.left]==0 && p.graph.nativeGains[.stereo]==0)
        #expect(clock.positions[.right]!>=3 && clock.positions[.right]!<3.3)
        #expect(clock.playerFrames.values.max()!-clock.playerFrames.values.min()!<=1)
        try record("pending-seek-source",["passed":true,"oldGraphStopped":!old.isPlaying,"destinationStillPlaying":p.isPlaying,"position":clock.positions[.right]!])
    }
    func pendingEpochMustNotWrapLoopBeforeOutgoingClockReachesBoundary() async throws {
        let (w,cap,_)=try await setup();defer{w.shutdown()}
        let old=try #require(cap.players[w.prepared!.url(for:.stereo)])
        w.loopStart=0.5;w.loopEnd=old.currentTime+0.055;w.looping=true
        let loopEnd=w.loopEnd
        #expect(w.switchAsset(.importedGuitarStem));let beforeTick=old.currentTime
        w.tick()
        try record("pending-loop",["outgoingTimeBeforeTick":beforeTick,"secondsBeforeBoundary":loopEnd-beforeTick,"loopEnd":loopEnd,"cursorAfterTick":w.cursor,"loopStart":w.loopStart,"outgoingIsPlayingAfterTick":old.isPlaying])
        if beforeTick<loopEnd-0.015 { #expect(w.cursor>=beforeTick-0.015,"Future destination anchor must not trigger a loop wrap while the actual outgoing clock is still before loopEnd") }
    }

    func independentFailedRedoRetainsTransactionNativeGainsAndCacheForRetry() async throws {
        let (w,cap,control)=try await setup();defer{w.shutdown()}
        w.project.events=helper.notes();let notes=w.project.events
        #expect(await w.setStemOffset(-0.5)?.value==true)
        w.undoEdit();#expect(w.project.stemAsset?.originalTimeOffset == -0.25 && w.canRedo)
        #expect(w.switchAsset(.importedGuitarStem));try await Task.sleep(for:.milliseconds(150))
        let stem=try #require(cap.players[w.prepared!.url(for:.stereo)]),dir=w.prepared!.directory,before=w.project
        control.failOriginalPlay=true;w.redoEdit()
        #expect(w.project==before && w.canRedo && !w.canUndo && w.playing && stem.isPlaying)
        #expect(stem.graph.nativeGains[.stereo]==1 && FileManager.default.fileExists(atPath:dir.path))
        control.failOriginalPlay=false;w.redoEdit()
        #expect(w.project.stemAsset?.originalTimeOffset == -0.5 && w.canUndo && !w.canRedo && w.project.events==notes)
        try record("failed-redo",["passed":true,"transactionRetainedOnFailure":true,"nativeGainRetained":true,"cacheRetained":true,"retryOffset":w.project.stemAsset!.originalTimeOffset])
    }
    func independentPendingEOFAndShutdownDoNotReviveOrDeleteUserMedia() async throws {
        let (w,cap,_)=try await setup()
        let oldAudio=try #require(w.prepared),old=try #require(cap.players[oldAudio.url(for:.stereo)])
        let originalBytes=try Data(contentsOf:oldAudio.original)
        w.seek(5.96);try await Task.sleep(for:.milliseconds(25))
        #expect(w.switchAsset(.importedGuitarStem))
        let stemAudio=try #require(w.prepared),stem=try #require(cap.players[stemAudio.url(for:.stereo)]),stemBytes=try Data(contentsOf:stemAudio.original)
        try await Task.sleep(for:.milliseconds(220));w.tick()
        #expect(!w.playing && w.cursor>=5.96 && w.cursor<6.0)
        w.shutdown();try await Task.sleep(for:.milliseconds(100))
        #expect(!old.isPlaying && !stem.isPlaying)
        #expect(!FileManager.default.fileExists(atPath:oldAudio.directory.path) && !FileManager.default.fileExists(atPath:stemAudio.directory.path))
        #expect(try Data(contentsOf:oldAudio.original)==originalBytes)
        #expect(try Data(contentsOf:stemAudio.original)==stemBytes)
        try record("eof-shutdown",["passed":true,"cursor":w.cursor,"ownedDirectoriesRemovedAfterStop":true,"fixtureMediaBytesRetained":true])
    }

    func pendingOffsetRateChangeKeepsTheReplacementStemGraph() async throws {
        let (w, cap, _) = try await setup(); defer { w.shutdown() }
        #expect(w.switchAsset(.importedGuitarStem))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await w.setStemOffset(-0.5)?.value == true)
        w.rate = 0.5
        try await Task.sleep(for: .milliseconds(180))
        #expect(w.switchAsset(.importedGuitarStem))
        let replacement = try #require(w.prepared)
        let native = try #require(cap.players[replacement.url(for: .stereo)])
        #expect(w.project.stemAsset?.originalTimeOffset == -0.5)
        #expect(native.isPlaying && native.graph.nativeGains[.stereo] == 1)
        #expect(WaveformEnvelope.peak(replacement.leftPeaks, duration: w.project.duration, from: 0.745, to: 0.755) > 0.79)
    }

}
@MainActor final class DeferredRegressionControl {
    var originalURLs: Set<URL> = []
    var failOriginalPlay = false
    var epochs: [UUID: Double] = [:]
    var monitoredStem: UUID?
    var originalPlayer: AudioEnginePlayer?
    var earlyStemRetirements: [Double] = []
    func retiring(_ native: any AudioPlayerTransport) {
        guard native.sharedClockID == monitoredStem, let originalPlayer,
              let epoch = epochs[originalPlayer.graph.id] else { return }
        let remaining = epoch - originalPlayer.deviceCurrentTime
        if remaining > 0 { earlyStemRetirements.append(remaining) }
    }
}
@MainActor final class DeferredRegressionPort:AudioPlayerTransport {
    let native:any AudioPlayerTransport;let url:URL;let control:DeferredRegressionControl
    init(native:any AudioPlayerTransport,url:URL,control:DeferredRegressionControl){self.native=native;self.url=url;self.control=control}
    var currentTime:Double{get{native.currentTime}set{native.currentTime=newValue}}
    var rate:Float{get{native.rate}set{native.rate=newValue}}
    var volume:Float{get{native.volume}set{if native.volume > 0 && newValue == 0 {control.retiring(native)};native.volume=newValue}}
    var enableRate:Bool{get{native.enableRate}set{native.enableRate=newValue}}
    var isPlaying:Bool{native.isPlaying};var deviceCurrentTime:Double{native.deviceCurrentTime};var sharedClockID:UUID?{native.sharedClockID}
    func clockSnapshot()->PlaybackClockSnapshot{native.clockSnapshot()}
    func prepareToPlay()->Bool{native.prepareToPlay()}
    func play()->Bool{!(control.failOriginalPlay && control.originalURLs.contains(url)) && native.play()}
    func play(atTime t:Double)->Bool{if let id=sharedClockID {control.epochs[id]=t};return !(control.failOriginalPlay && control.originalURLs.contains(url)) && native.play(atTime:t)}
    func pause(){control.retiring(native);native.pause()};func stop(){control.retiring(native);native.stop()}
}

extension StemWorkspaceTests {
    @Test func pendingOffsetRateChangeKeepsTheReplacementStemGraph() async throws {
        let probe = DeferredHandoverRegressionHarness()
        defer { try? FileManager.default.removeItem(at: probe.helper.evidence) }
        try await probe.pendingOffsetRateChangeKeepsTheReplacementStemGraph()
    }

    @Test func failedRapidReversalKeepsActualOutgoingAudioUntilPendingEpoch() async throws {
        let probe = DeferredHandoverRegressionHarness()
        defer { try? FileManager.default.removeItem(at: probe.helper.evidence) }
        try await probe.failedRapidReversalKeepsActualOutgoingAudioUntilPendingEpoch()
    }
    @Test func pendingRateChangePreservesCommonNativeOriginalTime() async throws {
        let probe = DeferredHandoverRegressionHarness()
        defer { try? FileManager.default.removeItem(at: probe.helper.evidence) }
        try await probe.pendingRateChangePreservesCommonNativeOriginalTime()
    }
    @Test func offsetCommitDoesNotStopOutgoingStemBeforeOriginalEpoch() async throws {
        let probe = DeferredHandoverRegressionHarness()
        defer { try? FileManager.default.removeItem(at: probe.helper.evidence) }
        try await probe.offsetCommitDoesNotStopOutgoingStemBeforeOriginalEpoch()
    }
    @Test func successfulRapidReversalKeepsAudibleClockAndDoesNotAdvanceFrozenPendingTime() async throws {
        let probe = DeferredHandoverRegressionHarness()
        defer { try? FileManager.default.removeItem(at: probe.helper.evidence) }
        try await probe.successfulRapidReversalKeepsAudibleClockAndDoesNotAdvanceFrozenPendingTime()
    }
    @Test func pauseBeforeHandoverEpochFreezesActualAudibleOriginalTime() async throws {
        let probe = DeferredHandoverRegressionHarness()
        defer { try? FileManager.default.removeItem(at: probe.helper.evidence) }
        try await probe.pauseBeforeHandoverEpochFreezesActualAudibleOriginalTime()
    }
    @Test func pendingSeekAndSourceChangesCancelOldEpochWithoutLateMuting() async throws {
        let probe = DeferredHandoverRegressionHarness()
        defer { try? FileManager.default.removeItem(at: probe.helper.evidence) }
        try await probe.pendingSeekAndSourceChangesCancelOldEpochWithoutLateMuting()
    }
    @Test func pendingEpochMustNotWrapLoopBeforeOutgoingClockReachesBoundary() async throws {
        let probe = DeferredHandoverRegressionHarness()
        defer { try? FileManager.default.removeItem(at: probe.helper.evidence) }
        try await probe.pendingEpochMustNotWrapLoopBeforeOutgoingClockReachesBoundary()
    }
    @Test func independentFailedRedoRetainsTransactionNativeGainsAndCacheForRetry() async throws {
        let probe = DeferredHandoverRegressionHarness()
        defer { try? FileManager.default.removeItem(at: probe.helper.evidence) }
        try await probe.independentFailedRedoRetainsTransactionNativeGainsAndCacheForRetry()
    }
    @Test func independentPendingEOFAndShutdownDoNotReviveOrDeleteUserMedia() async throws {
        let probe = DeferredHandoverRegressionHarness()
        defer { try? FileManager.default.removeItem(at: probe.helper.evidence) }
        try await probe.independentPendingEOFAndShutdownDoNotReviveOrDeleteUserMedia()
    }
}
