import AVFoundation
import Foundation
import RoughScoreCore
import Darwin

/// A staged asset owns one streaming render graph. There is exactly one rate processor after
/// the source mixer, so channel changes cannot create independent time-pitch timelines.
@MainActor
final class AudioEngineGraph {
    let id = UUID()
    let engine = AVAudioEngine()
    let mixer = AVAudioMixerNode()
    let timePitch = AVAudioUnitTimePitch()
    let duration: Double
    private let files: [ListeningSource: AVAudioFile]
    private let nodes: [ListeningSource: AVAudioPlayerNode]
    private var anchor = 0.0
    private var parked = 0.0
    private var running = false
    private var epoch: Double?
    private var generation = UUID()
    private var scheduled = false
    private var preparedGeneration: UUID?
    private var primed = false

    init(audio: PreparedAudio) throws {
        duration = audio.duration
        var files: [ListeningSource: AVAudioFile] = [:]
        var nodes: [ListeningSource: AVAudioPlayerNode] = [:]
        for source in [ListeningSource.stereo, .left, .right] {
            let file = try AVAudioFile(forReading: audio.url(for: source))
            guard file.length > 0, file.length <= Int64(UInt32.max),
                  (1...2).contains(file.processingFormat.channelCount) else { throw AudioIssue.unsupported }
            files[source] = file
            nodes[source] = AVAudioPlayerNode()
        }
        self.files = files; self.nodes = nodes
        guard let original = files[.stereo],
              let format = AVAudioFormat(standardFormatWithSampleRate: original.processingFormat.sampleRate, channels: 2)
        else { throw AudioIssue.unsupported }
        engine.attach(mixer); engine.attach(timePitch)
        for (index, source) in [ListeningSource.stereo, .left, .right].enumerated() {
            let node = nodes[source]!, file = files[source]!
            guard file.processingFormat.sampleRate == original.processingFormat.sampleRate,
                  file.length == original.length else { throw AudioIssue.unsupported }
            engine.attach(node)
            engine.connect(node, to: mixer, fromBus: 0, toBus: AVAudioNodeBus(index), format: file.processingFormat)
            node.volume = 0
        }
        engine.connect(mixer, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        timePitch.pitch = 0
    }

    var deviceTime: Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
    var isPlaying: Bool { running }
    func sourceIsPlaying(_ source: ListeningSource) -> Bool { running && nodes[source]?.isPlaying == true }
    var position: Double {
        guard running else { return parked }
        if let epoch, deviceTime < epoch { return anchor }
        // lastRenderTime is an arbitrary node timeline. playerTime converts it to frames consumed
        // in the INPUT/file domain; the shared rate unit has already determined that frame count.
        guard let clock = nodes[.stereo],
              let rendered = mixer.lastRenderTime,
              let played = clock.playerTime(forNodeTime: rendered), played.sampleTime >= 0
        else { return anchor }
        return min(duration, anchor + Double(played.sampleTime) / played.sampleRate)
    }

    struct InputClockSnapshot {
        let renderFrame: AVAudioFramePosition
        let sampleRate: Double
        let hostTime: UInt64
        let playerFrames: [ListeningSource: AVAudioFramePosition]
        let positions: [ListeningSource: Double]
    }

    /// One actual upstream render timestamp for every player; never compare stale per-node renders.
    func inputClockSnapshot() -> InputClockSnapshot? {
        guard let render = mixer.lastRenderTime else { return nil }
        var frames: [ListeningSource: AVAudioFramePosition] = [:]
        var positions: [ListeningSource: Double] = [:]
        for (source, node) in nodes {
            guard let player = node.playerTime(forNodeTime: render), player.sampleTime >= 0 else { continue }
            frames[source] = player.sampleTime
            positions[source] = anchor + Double(player.sampleTime) / player.sampleRate
        }
        return InputClockSnapshot(renderFrame: render.sampleTime, sampleRate: render.sampleRate,
                                  hostTime: render.hostTime, playerFrames: frames, positions: positions)
    }

    func nodePosition(_ source: ListeningSource) -> Double? { inputClockSnapshot()?.positions[source] }

    func setPosition(_ value: Double) {
        guard let bounded = TimeBounds.clamp(value, duration: duration) else { return }
        generation = UUID(); preparedGeneration = nil; running = false; epoch = nil
        for node in nodes.values { node.stop() }
        anchor = bounded; parked = bounded
        let token = generation
        for source in [ListeningSource.stereo, .left, .right] {
            let file = files[source]!, node = nodes[source]!
            let frame = min(file.length - 1, AVAudioFramePosition(floor(bounded * file.processingFormat.sampleRate)))
            let count = AVAudioFrameCount(file.length - frame)
            if source == .stereo {
                node.scheduleSegment(file, startingFrame: frame, frameCount: count, at: nil,
                                     completionCallbackType: .dataPlayedBack, completionHandler: { @Sendable [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        self.parked = self.duration; self.running = false; self.epoch = nil
                    }
                })
            } else {
                node.scheduleSegment(file, startingFrame: frame, frameCount: count, at: nil, completionHandler: nil)
            }
        }
        scheduled = true
    }

    func prepare() -> Bool {
        if !scheduled { setPosition(parked) }
        do {
            if preparedGeneration != generation {
                for node in nodes.values { node.prepare(withFrameCount: 4096) }
                preparedGeneration = generation
            }
            if !engine.isRunning { engine.prepare(); try engine.start() }
            if !primed {
                // Prime native node start machinery while every staged gain is still zero, before
                // any user-visible epoch is chosen. Restore the exact file anchor afterward.
                let position = parked
                for node in nodes.values { node.play() }
                for node in nodes.values { node.pause() }
                primed = true
                setPosition(position)
                for node in nodes.values { node.prepare(withFrameCount: 4096) }
                preparedGeneration = generation
            }
            return true
        } catch { return false }
    }

    func play(at time: Double?) -> Bool {
        if running, epoch == time { return true }
        guard prepare() else { return false }
        let start: AVAudioTime?
        if let time, let rendered = mixer.lastRenderTime, rendered.isSampleTimeValid {
            let sampleRate = files[.stereo]!.processingFormat.sampleRate
            let latest = ([rendered.sampleTime] + nodes.values.compactMap { $0.lastRenderTime?.sampleTime }).max()!
            let lead = AVAudioFramePosition(ceil(max(0, time - deviceTime) * sampleRate * Double(timePitch.rate)))
            start = AVAudioTime(sampleTime: latest + max(64, lead), atRate: sampleRate)
        } else {
            start = time.map { AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: $0)) }
        }
        for node in nodes.values { node.play(at: start) }
        running = nodes.values.allSatisfy(\.isPlaying)
        epoch = time
        if !running { pause() }
        return running
    }

    func pause() {
        guard running else { return }
        let position = self.position // Native playerTime can become nil as soon as pause completes.
        for node in nodes.values { node.pause() }
        parked = position; running = false; epoch = nil
    }

    func stop() {
        generation = UUID(); running = false; epoch = nil; scheduled = false
        for node in nodes.values { node.stop() }
        engine.stop()
    }

    var nativeGains: [ListeningSource: Float] { nodes.mapValues(\.volume) }
    func gain(_ source: ListeningSource, _ value: Float) { nodes[source]?.volume = value }
}

@MainActor
final class AudioEnginePlayer: AudioPlayerTransport {
    let graph: AudioEngineGraph
    let source: ListeningSource
    private var requestedVolume: Float = 1
    init(graph: AudioEngineGraph, source: ListeningSource) { self.graph = graph; self.source = source }
    var sharedClockID: UUID? { graph.id }
    var currentTime: Double { get { graph.position } set { graph.setPosition(newValue) } }
    var rate: Float { get { graph.timePitch.rate } set { graph.timePitch.rate = newValue } }
    var volume: Float { get { requestedVolume } set { requestedVolume = newValue; graph.gain(source, newValue) } }
    var enableRate: Bool { get { true } set { } }
    var isPlaying: Bool { graph.sourceIsPlaying(source) }
    var deviceCurrentTime: Double { graph.deviceTime }
    func prepareToPlay() -> Bool { graph.prepare() }
    func play() -> Bool { graph.play(at: nil) }
    func play(atTime time: TimeInterval) -> Bool { graph.play(at: time) }
    func pause() { graph.pause() }
    func stop() { graph.stop() }
}

/// Per-Workspace service state: old graphs stay alive through their transports; no global player cache.
@MainActor
final class AudioEngineTransportFactory {
    private final class Reference {
        weak var graph: AudioEngineGraph?
        let source: ListeningSource
        init(_ graph: AudioEngineGraph, _ source: ListeningSource) { self.graph = graph; self.source = source }
    }
    private var references: [URL: Reference] = [:]
    private var pending: AudioEngineGraph?
    private var pendingDirectory: URL?
    func prepare(_ audio: PreparedAudio) throws {
        let graph = try AudioEngineGraph(audio: audio)
        references = references.filter { $0.value.graph != nil }
        for source in [ListeningSource.right, .left, .stereo] {
            references[audio.url(for: source)] = Reference(graph, source)
        }
        pending = graph; pendingDirectory = audio.directory
    }
    func discard(_ audio: PreparedAudio) {
        guard pendingDirectory == audio.directory else { return }
        pending?.stop(); pending = nil; pendingDirectory = nil
        references = references.filter { $0.value.graph != nil }
    }
    func player(_ url: URL) throws -> any AudioPlayerTransport {
        guard let reference = references[url], let graph = reference.graph else { throw AudioIssue.unsupported }
        let player = AudioEnginePlayer(graph: graph, source: reference.source)
        if pending === graph { pending = nil; pendingDirectory = nil }
        return player
    }
}
