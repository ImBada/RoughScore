// Regression probes adapted from the independently reproduced PR #38 review.
import AppKit
import AVFoundation
import Foundation
import RoughScoreCore
import SwiftUI
import Testing
@testable import RoughScore

@MainActor @Suite(.serialized)
struct StemReviewRegressionTests {
    let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-pr38-regression-" + UUID().uuidString)
    func record(_ name: String, _ value: Any) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys]).write(to: evidence.appendingPathComponent(name+".json"))
    }
    func fixture(_ name: String, duration: Double = 6, padding: Double = 0, rate: Double = 48000, channels: AVAudioChannelCount = 2) throws -> URL {
        let dir = evidence.appendingPathComponent("generated-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url=dir.appendingPathComponent(name+".caf"), count=Int((duration+padding)*rate)
        let format=AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let b=AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!; b.frameLength=AVAudioFrameCount(count)
        for c in 0..<Int(channels) {
            b.floatChannelData![c].initialize(repeating: 0, count: count)
            let a=Int((1+padding+Double(c)*0.125)*rate)
            if a<count { b.floatChannelData![c][a]=c==0 ? 0.8 : -0.6 }
            for i in 1..<min(Int(0.3*rate),count-a) where a>=0 { b.floatChannelData![c][a+i]=Float(0.2*sin(2 * .pi * Double(c==0 ? 220:330)*Double(i)/rate)*exp(-Double(i)/(rate*0.07))) }
        }
        let f=try AVAudioFile(forWriting:url,settings:format.settings);try f.write(from:b);f.close();return url
    }
    func services(_ capture: StemReviewCapture = StemReviewCapture()) -> WorkspaceServices {
        var s=WorkspaceServices.live;s.lastProject={nil};s.rememberProject={_ in};s.chooseSaveDestination={_ in nil}
        let make=s.makePlayer
        s.makePlayer={url in
            let p=try #require(make(url) as? AudioEnginePlayer);p.graph.engine.mainMixerNode.outputVolume=0
            capture.players[url]=p
            return p
        };return s
    }
    func notes()->[TabEvent] {
        [TabEvent(id:UUID(uuidString:"CB0FA5D6-6596-471F-BB2B-48B0B9B03E61")!,time:1.000000012345,lane:.left,string:6,memo:"한글\n?"),
         TabEvent(id:UUID(uuidString:"EDD16A11-F94B-4D80-B34B-C6E03292DA0A")!,time:2.123456789012,lane:.right,string:2,fret:12,length:nil,tentative:true,memo:"manual"),
         TabEvent(time:2.123456789012,lane:.right,string:2,fret:0,memo:"same time")]
    }
    @Test func independentCrossGraphCommonHostTimeCutover() async throws {
        defer { try? FileManager.default.removeItem(at: evidence) }
        let o=try fixture("clock-original",duration:12,rate:44100),s=try fixture("clock-stem",duration:12,padding:0.25)
        let cap=StemReviewCapture(),w=Workspace(services:services(cap));defer{w.shutdown()}
        #expect(await w.loadAudio(at:o)?.value==true); #expect(await w.attachStem(at:s,offset:-0.25)?.value==true)
        var rows:[[String:Any]]=[]
        for rate:Float in [0.5,0.75,1] {
            w.rate=rate;#expect(w.switchAsset(.original));w.seek(1.7);w.togglePlayback();try await Task.sleep(for:.milliseconds(350))
            for role in [AudioAsset.Role.importedGuitarStem,.original,.importedGuitarStem,.original] {
                let old=try #require(cap.players[w.prepared!.url(for:.stereo)]),before=try #require(old.graph.inputClockSnapshot())
                let oldPosition=try #require(before.positions[.stereo]);#expect(w.switchAsset(role))
                let new=try #require(cap.players[w.prepared!.url(for:.stereo)])
                try await Task.sleep(for:.milliseconds(120))
                let after=try #require(new.graph.inputClockSnapshot()),newPosition=try #require(after.positions[.stereo])
                let delta=AVAudioTime.seconds(forHostTime:after.hostTime)-AVAudioTime.seconds(forHostTime:before.hostTime)
                let error=newPosition-(oldPosition+delta*Double(rate))
                rows.append(["rate":rate,"oldGraph":old.graph.id.uuidString,"newGraph":new.graph.id.uuidString,"oldInputTime":oldPosition,"newInputTime":newPosition,"hostDelta":delta,"commonTimeErrorSeconds":error,"oldFrames":before.playerFrames.values.map{Int($0)},"newFrames":after.playerFrames.values.map{Int($0)}])
                try record("own-cross-graph-clock",rows)
                #expect(abs(error)<=0.015,"Different native graphs must preserve common-host-time original position; measured \(error)s")
            }
            w.togglePlayback()
        }
    }

    @Test func failedOffsetUndoMustRetainHistoryAndLease() async throws {
        defer { try? FileManager.default.removeItem(at: evidence) }
        let o=try fixture("undo-original"),s=try fixture("undo-stem",padding:0.25)
        let cap=StemReviewCapture(),control=StemReviewFailure(),base=services(cap)
        var service=base;let make=base.makePlayer
        service.makePlayer={url in StemReviewFailPort(native:try make(url),url:url,control:control)}
        let w=Workspace(services:service);defer{w.shutdown()}
        #expect(await w.loadAudio(at:o)?.value==true);w.project.events=notes();let manual=w.project.events
        let original=try #require(w.prepared);control.originalURLs=Set(ListeningSource.allCases.map{original.url(for:$0)})
        #expect(await w.attachStem(at:s,offset:-0.25)?.value==true)
        #expect(await w.setStemOffset(-0.5)?.value==true && w.canUndo)
        #expect(w.switchAsset(.importedGuitarStem));w.seek(0.5);w.togglePlayback();try await Task.sleep(for:.milliseconds(100))
        let before=w.project;control.failOriginalPlay=true;w.undoEdit()
        let failedState:[String:Any]=["offset":w.project.stemAsset!.originalTimeOffset,"canUndo":w.canUndo,"canRedo":w.canRedo,"manualUnchanged":w.project.events==manual,"projectUnchanged":w.project==before,"error":w.error ?? "nil","status":w.status]
        #expect(w.project==before && w.project.events==manual)
        #expect(w.canUndo,"Failed offset undo must not consume the only undo transaction")
        #expect(!w.canRedo && w.assetRole == .importedGuitarStem && w.playing)
        let retainedAudio = try #require(w.prepared)
        #expect(FileManager.default.fileExists(atPath: retainedAudio.directory.path))
        control.failOriginalPlay=false;w.undoEdit()
        try record("own-offset-undo-failure",["afterFailure":failedState,"offsetAfterRetry":w.project.stemAsset!.originalTimeOffset,"canUndoAfterRetry":w.canUndo,"canRedoAfterRetry":w.canRedo])
        #expect(w.project.stemAsset?.originalTimeOffset == -0.25,"Retry after native play failure must undo the still-pending offset transaction")
        #expect(w.canRedo && !w.canUndo && w.switchAsset(.importedGuitarStem))
        try await Task.sleep(for: .milliseconds(100))
        let undone = w.project, undoAudio = try #require(w.prepared)
        control.failOriginalPlay = true; w.redoEdit()
        #expect(w.project == undone && w.canRedo && !w.canUndo && w.playing)
        #expect(FileManager.default.fileExists(atPath: undoAudio.directory.path))
        control.failOriginalPlay = false; w.redoEdit()
        #expect(w.project.stemAsset?.originalTimeOffset == -0.5 && w.canUndo && !w.canRedo)
        #expect(w.project.events == manual)
    }

    @Test func readableChangedStemDuringOriginalRelinkMustInvalidateContradictedProvenance() async throws {
        defer { try? FileManager.default.removeItem(at: evidence) }
        let o=try fixture("relink-original"),s=try fixture("relink-stem",padding:0.25),replacement=try fixture("new-stem",padding:0.25)
        var service=services();service.analyze={_,_ in AnalysisSummary(beats:[1],bars:[1])}
        let w=Workspace(services:service);defer{w.shutdown()};#expect(await w.loadAudio(at:o)?.value==true)
        #expect(await w.attachStem(at:s,offset:-0.25)?.value==true && w.switchAsset(.importedGuitarStem));await w.analyze()?.value
        let stemID=try #require(w.project.stemAsset?.id),oldIdentity=w.project.stemAsset?.identity
        // Byte-readable, independently encoded replacement; changed sample data rather than missing media.
        var bytes=try Data(contentsOf:replacement);bytes[bytes.count-4] ^= 1;try bytes.write(to:s)
        #expect(await w.loadAudio(at:o,relink:true)?.value==true)
        let retained=w.project.analyses.values.filter{$0.provenance?.assetID==stemID}.count
        try record("own-relink-replaced-stem",["stemProvenanceCountAfterContradiction":retained,"stemIdentityStillOld":w.project.stemAsset?.identity==oldIdentity,"originalAvailable":w.prepared != nil,"status":w.stemConnection])
        #expect(retained==0,"Original relink observed a changed readable stem but retained its disproven analysis")
        #expect(w.project.stemAsset?.identity==nil,"Readable changed stem must clear contradicted source identity as project-open does")
    }

    @Test func actualScoreContainerPreservesBrowsedStemPageOnSummaryOnlyUpdate() async throws {
        defer { try? FileManager.default.removeItem(at: evidence) }
        let original=try fixture("score-original",duration:60),stem=try fixture("score-stem",duration:60,padding:0.25)
        let w=Workspace(services:services());defer{w.shutdown()};#expect(await w.loadAudio(at:original)?.value==true)
        #expect(await w.attachStem(at:stem,offset:-0.25)?.value==true)
        w.project.analyses["stereo"]=AnalysisSummary(bars:Array(stride(from:0.0,to:60.0,by:2.0)))
        let key=w.project.analysisKey(asset:w.project.stemAsset,channel:.stereo)
        w.project.analyses[key]=AnalysisSummary(bars:Array(stride(from:0.0,to:60.0,by:0.25)))
        #expect(w.switchAsset(.importedGuitarStem));let host=NotePointerTests.Host(ScoreSheetView(workspace:w),height:900,width:1100);defer{host.close()};host.settle()
        w.browseScorePage(2);host.settle();let page=w.scorePage,start=w.scoreLayout.rows(on:page).first!.start
        w.project.analyses[key]?.bpm=123;host.settle()
        try record("own-score-container-stem-page",["beforePage":page,"afterPage":w.scorePage,"beforeStartSeconds":start,"afterStartSeconds":w.scoreLayout.rows(on:w.scorePage).first!.start,"barCoordinatesUnchanged":true,"activeRole":String(describing:w.assetRole)])
        #expect(w.scorePage==page,"An active-stem BPM-only update must not re-anchor a manually browsed page through Original's unrelated bar layout")
    }

}
@MainActor final class StemReviewCapture {var players:[URL:AudioEnginePlayer]=[:]}
@MainActor final class StemReviewFailure {var failOriginalPlay=false;var originalURLs:Set<URL>=[]}
@MainActor final class StemReviewFailPort:AudioPlayerTransport {
 let native:any AudioPlayerTransport;let url:URL;let control:StemReviewFailure
 init(native:any AudioPlayerTransport,url:URL,control:StemReviewFailure){self.native=native;self.url=url;self.control=control}
 var currentTime:Double{get{native.currentTime}set{native.currentTime=newValue}};var rate:Float{get{native.rate}set{native.rate=newValue}};var volume:Float{get{native.volume}set{native.volume=newValue}};var enableRate:Bool{get{native.enableRate}set{native.enableRate=newValue}};var isPlaying:Bool{native.isPlaying};var deviceCurrentTime:Double{native.deviceCurrentTime};var sharedClockID:UUID?{native.sharedClockID}
 func prepareToPlay()->Bool{native.prepareToPlay()};func play()->Bool{!(control.failOriginalPlay && control.originalURLs.contains(url)) && native.play()};func play(atTime t:Double)->Bool{!(control.failOriginalPlay && control.originalURLs.contains(url)) && native.play(atTime:t)};func pause(){native.pause()};func stop(){native.stop()}
 func clockSnapshot() -> PlaybackClockSnapshot { native.clockSnapshot() }
}
