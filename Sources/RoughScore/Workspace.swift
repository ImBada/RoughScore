import AppKit
import AVFoundation
import Combine
import RoughScoreCore
import UniformTypeIdentifiers

@MainActor
final class Workspace: ObservableObject {
    @Published var project = ScoreProject.demo
    @Published var prepared: PreparedAudio?
    @Published private(set) var audioConnection = "오디오 준비 전"
    @Published var source: ListeningSource = .stereo
    @Published var lane: GuitarLane = .left
    @Published var activeString = 6
    @Published var selectedID: UUID?
    @Published var cursor = 2.0
    @Published private(set) var entryInterval = 0.05
    @Published var windowStart = 0.0
    @Published var windowLength = 12.0
    @Published var loopStart = 2.0
    @Published var loopEnd = 6.0
    @Published var looping = false
    @Published var playing = false
    @Published var rate: Float = 1 { didSet { if rate != oldValue { updatePlaybackRate() } } }
    @Published var showLengths = false
    @Published var snapToBeat = false
    @Published private(set) var busy = false
    @Published private(set) var loadProgress = 0.0
    @Published var analyzing = false
    @Published var status = "데모 준비 중"
    @Published var error: String?
    @Published var isDemo = true
    @Published private(set) var saveState: SaveState = .unsaved
    @Published var dirty = false
    enum SaveState: Equatable {
        case unsaved, pending, saving, saved, failed, cancelled
        var title: String {
            switch self {
            case .unsaved: "미저장 · ⌘S"
            case .pending: "변경됨 · 자동 저장 대기"
            case .saving: "저장 중…"
            case .saved: "저장됨"
            case .failed: "저장 실패 · 미저장"
            case .cancelled: "저장 취소 · 미저장"
            }
        }
    }
    @Published var scoreView = true
    @Published var measuresPerSystem = 4
    @Published var scorePage = 0
    @Published var showBothLanes = false
    @Published var showScoreWaveforms = true
    @Published var followScore = true
    @Published var inspectorVisible = false
    @Published private(set) var positionDrag: TabEvent?
    @Published private(set) var positionMagnetTargetID: UUID?
    private struct MagnetDragInput {
        let time: Double
        let string: Int
        let screenX: Double
        let anchors: [NoteMagnetAnchor]
    }
    private var magnetDragInput: MagnetDragInput?
    var requestKeyboardFocus: (() -> Void)?
    private var fretEntry = FretEntryBuffer()
    private var newlyCreatedID: UUID?
    private struct EditSnapshot {
        let id = UUID()
        let events: [TabEvent]
        let selectedID: UUID?
        let activeString: Int
    }
    private var undoHistory: [EditSnapshot] = []
    private var redoHistory: [EditSnapshot] = []
    private struct MemoSession {
        let projectID: UUID
        let eventID: UUID
        let baseline: [TabEvent]
        var undoID: UUID?
    }
    private var memoSession: MemoSession?
    private var nativeTextObserver: AnyCancellable?
    private var savedProject: ScoreProject?
    private var autosaveTask: Task<Void, Never>?
    private var projectURL: URL?
    private var projectRevision: UInt64 = 0
    private var player: (any AudioPlayerTransport)?
    private struct PreparedPlayer {
        let transport: any AudioPlayerTransport
        let volume: Float
        var warmedRate: Float? = nil
        var scheduledEpoch: Double? = nil
    }
    private struct ScheduledStart {
        let epoch: Double
        let position: Double
    }
    private var scheduledStart: ScheduledStart?
    private var preparedPlayers: [ListeningSource: PreparedPlayer] = [:]
    private var timer: Timer?
    private var analysisTask: Task<Void, Never>?
    private var demoURL: URL?
    private let services: WorkspaceServices
    private var startupPending: Bool
    private var started = false
    private var closed = false
    private var projectIdentity = UUID()
    private var loadTask: Task<Bool, Never>?
    private var loadOperation: LoadOperation?
    private var analysisID: UUID?

    private struct LoadOperation: Sendable {
        let id = UUID()
        let projectID: UUID
        let snapshot: ScoreProject
    }
    private enum LoadRequest: Sendable {
        case startup, demo(Bool), audio(URL, Bool), project(URL)
    }
    private struct StagedWorkspace: Sendable {
        var project: ScoreProject
        var audio: PreparedAudio?
        var projectURL: URL?
        var demoURL: URL?
        var isDemo = false
        var fromDisk = false
        var baseline: ScoreProject?
        var status: String
        var offlineReason: String?
    }

    init(services: WorkspaceServices = .live, awaitsStartup: Bool = false) {
        self.services = services
        startupPending = awaitsStartup
        busy = awaitsStartup
        nativeTextObserver = NotificationCenter.default.publisher(for: NSText.didChangeNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                self.objectWillChange.send()
            }
        }
    }

    var canEdit: Bool { !busy && !closed }
    var canLoad: Bool { canEdit && !analyzing }
    var canMutateNotes: Bool { canEdit && positionDrag == nil }


    var windowEnd: Double { min(project.duration, windowStart + windowLength) }
    var visibleEvents: [TabEvent] {
        project.events.filter { $0.lane == lane && $0.time >= windowStart && $0.time < windowEnd }
    }
    var selected: TabEvent? { project.events.first { $0.id == selectedID } }
    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    var canPerformUndo: Bool { canEdit && (services.nativeTextUndo()?.canUndo ?? canUndo) }
    var canPerformRedo: Bool { canMutateNotes && (services.nativeTextUndo()?.canRedo ?? canRedo) }
    func performUndo() {
        guard canEdit else { return }
        if let target = services.nativeTextUndo() { target.undo(); return }
        undoEdit()
    }
    func performRedo() {
        guard canMutateNotes else { return }
        if let target = services.nativeTextUndo() { target.redo(); return }
        redoEdit()
    }
    var hasSaveLocation: Bool { projectURL != nil }
    var summary: AnalysisSummary? { project.analyses[source.rawValue] }
    var scoreSummary: AnalysisSummary? {
        project.analyses["stereo"] ?? summary ?? project.analyses["left"] ?? project.analyses["right"]
    }
    var scoreLayout: ScoreLayout {
        ScoreLayout(duration: project.duration, bars: scoreSummary?.bars ?? [], measuresPerSystem: measuresPerSystem,
                    systemsPerPage: showBothLanes ? 2 : 4)
    }
    var displayedScorePage: Int { min(max(0, scorePage), scoreLayout.pageCount - 1) }
    var canAnalyze: Bool {
        #if canImport(MusicUnderstanding)
        if #available(macOS 27.0, *) { return prepared != nil && !busy }
        #endif
        return false
    }

    /// Reserve startup before returning to SwiftUI; the app also locks its initial view before .task runs.
    @discardableResult
    func start() -> Task<Bool, Never>? {
        guard !started, !closed else { return nil }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        guard let operation = reserveLoad() else { return nil }
        return launchLoad(.startup, operation: operation)
    }

    func tick() {
        guard playing, let player else { return }
        if looping && livePlayerTime(player) >= loopEnd {
            startPlayers(at: loopStart)
        } else if !player.isPlaying {
            pausePlayers()
            playing = false
        }
        cursor = boundedPlaybackTime(livePlayerTime(player))
        if followScore && selectedID == nil && positionDrag == nil { followScoreCursor() }
        if selectedID == nil && positionDrag == nil && (cursor >= windowEnd || cursor < windowStart) {
            windowStart = max(0, min(project.duration - min(windowLength, project.duration), floor(cursor / windowLength) * windowLength))
        }
    }

    func seek(_ time: Double) {
        guard let bounded = TimeBounds.clamp(time, duration: project.duration) else { return }
        cursor = bounded
        if looping && (cursor < loopStart || cursor >= loopEnd) { looping = false }
        if playing { startPlayers(at: cursor) }
        else { for cached in preparedPlayers.values { cached.transport.currentTime = cursor } }
        if cursor < windowStart || cursor >= windowEnd {
            windowStart = min(cursor, max(0, project.duration - windowLength))
        }
        if followScore { followScoreCursor() }
    }

    func seekForEditing(_ time: Double, lane: GuitarLane? = nil) {
        guard canMutateNotes, let bounded = TimeBounds.clamp(time, duration: project.duration) else { return }
        endMemoEditing()
        fretEntry.reset(); newlyCreatedID = nil; selectedID = nil
        if let lane { selectLane(lane) }
        jumpToScoreTime(bounded); requestKeyboardFocus?()
        status = "\(clockLabel(cursor)) · \(activeString)번 줄에 숫자로 입력 · 파형 드래그로 반복"
    }
    func selectLane(_ value: GuitarLane) {
        guard canMutateNotes else { return }
        lane = value
        if source != .stereo { switchSource(value == .left ? .left : .right) }
    }

    func followScoreCursor() {
        let page = scoreLayout.page(at: cursor)
        if scorePage != page { scorePage = page }
    }
    func reflowScore(from previous: ScoreLayout) {
        let anchor = followScore ? cursor : (previous.rows(on: scorePage).first?.start ?? cursor)
        scorePage = scoreLayout.page(at: anchor)
    }
    func browseScorePage(_ page: Int) {
        scorePage = min(max(0, page), scoreLayout.pageCount - 1)
        followScore = false
    }
    func jumpToScoreTime(_ time: Double) {
        seek(time); scorePage = scoreLayout.page(at: cursor)
    }
    func editSystem(_ row: ScoreSystem) {
        windowLength = row.end - row.start; windowStart = row.start
        jumpToScoreTime(row.start); scoreView = false
    }

    func togglePlayback() {
        guard canEdit, let player else { return }
        if playing {
            pausePlayers()
            cursor = boundedPlaybackTime(livePlayerTime(player))
            playing = false
        } else {
            if looping && (cursor < loopStart || cursor >= loopEnd) { seek(loopStart) }
            startPlayers(at: cursor)
        }
    }

    /// AV currentTime may project behind the seek while a future device start is queued.
    /// That queued transport has not consumed any song frames yet; its live position is the anchor.
    private func livePlayerTime(_ transport: (any AudioPlayerTransport)?) -> Double {
        guard let transport else { return cursor }
        if let pending = scheduledStart {
            if transport.deviceCurrentTime < pending.epoch { return pending.position }
            let time = transport.currentTime
            if time < pending.position { return pending.position }
            scheduledStart = nil
            return time
        }
        return transport.currentTime
    }

    private func pausePlayers() {
        let pending = scheduledStart
        let restoreAnchor = pending.map { pending in
            player.map { $0.deviceCurrentTime < pending.epoch || $0.currentTime < pending.position } ?? false
        } ?? false
        player?.pause()
        for cached in preparedPlayers.values where cached.transport !== player { cached.transport.pause() }
        if restoreAnchor, let pending {
            for cached in preparedPlayers.values { cached.transport.currentTime = pending.position }
        }
        for (value, var cached) in preparedPlayers {
            cached.scheduledEpoch = nil; preparedPlayers[value] = cached
        }
        scheduledStart = nil
    }

    private func updatePlaybackRate() {
        let resume = playing
        pausePlayers()
        if resume, let player { cursor = boundedPlaybackTime(livePlayerTime(player)) }
        for cached in preparedPlayers.values where cached.transport.rate != rate { cached.transport.rate = rate }
        if resume { startPlayers(at: cursor) }
    }

    private func cachedPlayer(for value: ListeningSource, audio: PreparedAudio) throws -> PreparedPlayer {
        if let cached = preparedPlayers[value] { return cached }
        let identity = projectIdentity
        let transport = try services.makePlayer(audio.url(for: value))
        transport.enableRate = true; transport.rate = rate
        guard transport.prepareToPlay() else { throw AudioIssue.playbackFailed }
        guard canEdit, projectIdentity == identity, prepared?.directory == audio.directory else { throw CancellationError() }
        let cached = PreparedPlayer(transport: transport, volume: transport.volume)
        preparedPlayers[value] = cached
        return cached
    }

    /// All ready channels consume the same original-song frames on one native device clock.
    /// Inactive channels stay muted and running, so a gain change requires no resume/seek rebuild.
    private func startPlayers(at time: Double) {
        guard let prepared, let player else { playing = false; return }
        let identity = projectIdentity
        for value in [ListeningSource.stereo, .left, .right] {
            // A failed inactive channel must not prevent the usable selected transport from playing.
            _ = try? cachedPlayer(for: value, audio: prepared)
        }
        guard !closed, projectIdentity == identity, self.prepared?.directory == prepared.directory,
              self.player === player else { return }
        pausePlayers()
        // prepareToPlay alone can leave a cold rate renderer inside the first play call. Warm it
        // once per rate while muted, before positioning any channel at the common starting frame.
        for (value, var cached) in preparedPlayers {
            if cached.transport.rate != rate { cached.transport.rate = rate }
            cached.transport.volume = 0
            if cached.warmedRate != rate {
                cached.transport.currentTime = 0
                if cached.transport.play() { cached.warmedRate = rate }
                cached.transport.pause()
                preparedPlayers[value] = cached
            }
        }
        guard !closed, projectIdentity == identity, self.prepared?.directory == prepared.directory,
              self.player === player else { return }
        var ready: [ListeningSource: PreparedPlayer] = [:]
        for (value, cached) in preparedPlayers {
            cached.transport.currentTime = time
            cached.transport.volume = value == source ? cached.volume : 0
            // A seek invalidates render preparation; finish it before choosing the shared epoch.
            if cached.warmedRate == rate && cached.transport.prepareToPlay() { ready[value] = cached }
        }
        guard ready[source] != nil else {
            playing = false; error = AudioIssue.playbackFailed.localizedDescription
            return
        }
        let epoch = player.deviceCurrentTime + 0.25
        for (value, var cached) in ready where value != source {
            cached.scheduledEpoch = cached.transport.play(atTime: epoch) && cached.transport.isPlaying ? epoch : nil
            if cached.scheduledEpoch == nil { cached.transport.pause() }
            preparedPlayers[value] = cached
        }
        playing = player.play(atTime: epoch) && player.isPlaying
        if playing, var cached = preparedPlayers[source] {
            cached.scheduledEpoch = epoch; preparedPlayers[source] = cached
            scheduledStart = ScheduledStart(epoch: epoch, position: time)
        }
        cursor = time
        if !playing {
            pausePlayers()
            error = AudioIssue.playbackFailed.localizedDescription
        }
    }

    private func boundedPlaybackTime(_ liveTime: Double) -> Double {
        TimeBounds.clamp(liveTime, duration: project.duration) ??
            TimeBounds.clamp(cursor, duration: project.duration) ?? 0
    }

    func switchSource(_ value: ListeningSource) {
        guard canMutateNotes, value != source else { return }
        let previousLayout = scoreLayout
        if let prepared {
            let identity = projectIdentity
            do {
                // Prepare before sampling the clock: decoding/setup must not freeze or rewind the old player.
                var cached = try cachedPlayer(for: value, audio: prepared)
                let destination = cached.transport
                let old = player
                let oldDeviceBefore = old?.deviceCurrentTime ?? destination.deviceCurrentTime
                var sampledTime = livePlayerTime(old)
                let oldDeviceAfter = old?.deviceCurrentTime ?? destination.deviceCurrentTime
                var liveTime = boundedPlaybackTime(sampledTime)
                var loopWrap = looping && sampledTime.isFinite && sampledTime >= loopEnd
                var resume = playing && (old?.isPlaying == true || loopWrap)
                if destination.rate != rate { destination.rate = rate }
                let target = loopWrap ? loopStart : liveTime
                let newDeviceBefore = destination.deviceCurrentTime
                let destinationTime = destination.currentTime
                let newDeviceAfter = destination.deviceCurrentTime
                let elapsedMinimum = max(0, newDeviceBefore - oldDeviceAfter)
                let elapsedMaximum = max(0, newDeviceAfter - oldDeviceBefore)
                // A native position read can sample anywhere within its device-clock bracket.
                // Compare the projected interval, rather than pretending either getter's completion
                // timestamp is the exact sample instant and mistaking elapsed progress for drift.
                let queuedAtAnchor = scheduledStart.map { pending in
                    cached.scheduledEpoch == pending.epoch
                } ?? false
                let aligned = destination.isPlaying && (queuedAtAnchor ||
                    (destinationTime >= target + elapsedMinimum * Double(rate) - 0.015 &&
                     destinationTime <= target + elapsedMaximum * Double(rate) + 0.015))
                if resume && !aligned {
                    cached.scheduledEpoch = nil; preparedPlayers[value] = cached
                    destination.volume = 0
                    destination.currentTime = target
                    if !destination.isPlaying {
                        guard destination.play() && destination.isPlaying else {
                            destination.pause()
                            preparedPlayers.removeValue(forKey: value)
                            throw AudioIssue.playbackFailed
                        }
                        // Cold recovery after an earlier inactive-channel failure still samples the old
                        // live clock after warm-up. Normal switches reuse the running common-clock group.
                        sampledTime = livePlayerTime(old)
                        liveTime = boundedPlaybackTime(sampledTime)
                        loopWrap = looping && sampledTime.isFinite && sampledTime >= loopEnd
                        resume = playing && (old?.isPlaying == true || loopWrap)
                        destination.currentTime = loopWrap ? loopStart : liveTime
                    }
                } else if !resume {
                    pausePlayers()
                    destination.currentTime = target
                }
                if loopWrap && resume {
                    // A switch may observe the loop boundary before the 30ms tick. Re-anchor every
                    // channel together so subsequent switches retain the same loop clock.
                    startPlayers(at: loopStart)
                    guard destination.isPlaying else { throw AudioIssue.playbackFailed }
                }
                guard canMutateNotes, projectIdentity == identity,
                      self.prepared?.directory == prepared.directory else {
                    destination.pause(); throw CancellationError()
                }
                if scheduledStart != nil && cached.scheduledEpoch != scheduledStart?.epoch { scheduledStart = nil }
                old?.volume = 0
                destination.volume = cached.volume
                if !resume { destination.pause() }
                player = destination
                cursor = loopWrap ? loopStart : liveTime
                playing = resume && destination.isPlaying
            } catch {
                playing = player?.isPlaying == true
                self.error = error.localizedDescription
                return
            }
        }
        source = value
        if value != .stereo {
            lane = value == .left ? .left : .right
            if let selected, selected.lane != lane { clearSelection() }
        }
        reflowScore(from: previousLayout)
    }

    func moveWindow(_ direction: Double) {
        windowStart = min(max(0, windowStart + direction * windowLength), max(0, project.duration - windowLength))
    }

    func setLoopStart() {
        guard canEdit else { return }
        loopStart = min(cursor, max(0, project.duration - 0.05))
        if loopEnd <= loopStart { loopEnd = min(project.duration, loopStart + 4) }
        looping = true
    }
    func setLoopEnd() {
        guard canEdit else { return }
        loopEnd = min(project.duration, max(loopStart + 0.05, cursor))
        looping = true
    }

    func setLoop(from start: Double, to end: Double) {
        guard canEdit else { return }
        guard start.isFinite, end.isFinite else { return }
        loopStart = min(max(0, min(start, end)), max(0, project.duration - 0.05))
        loopEnd = min(project.duration, max(loopStart + 0.05, max(start, end)))
        looping = true
        seekForEditing(loopStart)
        status = "\(clockLabel(loopStart)) — \(clockLabel(loopEnd)) 반복 · Space로 재생"
    }

    func addEvent(time: Double, string: Int, matchingExisting: Bool = true) {
        guard canMutateNotes else { return }
        guard time.isFinite, (1...6).contains(string) else { return }
        let snapped = TabMath.snap(time, beats: scoreSummary?.beats ?? [], enabled: snapToBeat)
        guard let actual = TimeBounds.clamp(snapped, duration: project.duration) else { return }
        activeString = string
        if matchingExisting, let existing = project.events.first(where: { $0.lane == lane && $0.string == string && abs($0.time - actual) < 0.04 }) {
            select(existing); return
        }
        recordUndo()
        let event = TabEvent(time: actual, lane: lane, string: string)
        project.events.append(event); selectedID = event.id; dirty = true; jumpToScoreTime(actual)
        fretEntry.reset(); newlyCreatedID = event.id
        requestKeyboardFocus?(); changed()
        status = "숫자를 입력하세요 · 10–24는 이어서 입력 · Delete 삭제 / ⌘Z 취소"
    }

    func select(_ event: TabEvent) {
        guard canMutateNotes, let actual = project.events.first(where: { $0.id == event.id }) else { return }
        endMemoEditing()
        fretEntry.reset(); newlyCreatedID = nil
        selectedID = actual.id; activeString = actual.string; selectLane(actual.lane); jumpToScoreTime(actual.time)
        requestKeyboardFocus?()
        status = "숫자로 프렛 변경 · ↑↓ 줄 이동 · ←→ 위치 이동 · Tab 다음 음"
    }

    func inputDigit(_ digit: Int, at time: Double = ProcessInfo.processInfo.systemUptime) {
        guard canMutateNotes else { return }
        guard (0...9).contains(digit), time.isFinite else { return }
        if selectedID == nil { addEvent(time: cursor, string: activeString, matchingExisting: false) }
        guard let selectedID, let index = project.events.firstIndex(where: { $0.id == selectedID }) else { return }
        guard let update = fretEntry.push(digit: digit, eventID: selectedID, now: time) else {
            status = "프렛은 0–24까지 입력할 수 있습니다"
            return
        }
        if update.startsNewEntry && newlyCreatedID != selectedID { recordUndo() }
        newlyCreatedID = nil
        project.events[index].fret = update.fret
        changed(); status = "\(project.events[index].string)번 줄 · \(update.fret)프렛 · 다음 위치를 클릭해서 계속 입력"
    }

    func updateSelected(_ change: (inout TabEvent) -> Void) {
        endMemoEditing()
        applySelected(change, coalescingMemo: false)
    }

    private func applySelected(_ change: (inout TabEvent) -> Void, coalescingMemo: Bool) {
        guard canMutateNotes else { return }
        guard let index = project.events.firstIndex(where: { $0.id == selectedID }) else { return }
        let original = project.events[index]
        var updated = original
        change(&updated)
        guard updated.id == original.id,
              let time = TimeBounds.clamp(updated.time, duration: project.duration) else { return }
        updated.time = time
        guard updated != original else { return }
        var candidate = project
        candidate.events[index] = updated
        guard (try? candidate.validated()) != nil else { return }
        if coalescingMemo, var session = memoSession, session.projectID == projectIdentity, session.eventID == original.id {
            if session.undoID == nil { session.undoID = recordUndo(coalescingMemo: true) }
            memoSession = session
        } else { recordUndo() }
        fretEntry.reset(); newlyCreatedID = nil
        project = candidate; activeString = updated.string; changed()
        if var session = memoSession, project.events == session.baseline,
           let undoID = session.undoID, undoHistory.last?.id == undoID {
            undoHistory.removeLast(); session.undoID = nil; memoSession = session
        }
    }

    func renderedEvent(_ event: TabEvent) -> TabEvent {
        positionDrag?.id == event.id ? positionDrag! : event
    }
    func beginPositionDrag(_ event: TabEvent) {
        guard canMutateNotes else { return }
        endMemoEditing()
        guard !busy, let actual = project.events.first(where: { $0.id == event.id }) else { return }
        fretEntry.reset(); newlyCreatedID = nil
        selectedID = actual.id; lane = actual.lane; activeString = actual.string
        positionDrag = actual
        positionMagnetTargetID = nil; magnetDragInput = nil
        requestKeyboardFocus?()
    }
    func previewPositionDrag(time: Double, string: Int, snap: Bool = true) {
        guard canEdit else { return }
        guard time.isFinite, var preview = positionDrag else { return }
        positionMagnetTargetID = nil; magnetDragInput = nil
        let snapped = TabMath.snap(time, beats: scoreSummary?.beats ?? [], enabled: snap && snapToBeat)
        guard let bounded = TimeBounds.clamp(snapped, duration: project.duration) else { return }
        preview.time = bounded
        preview.string = min(6, max(1, string))
        positionDrag = preview
        status = "\(String(format: "%.3f", preview.time))초 · \(preview.string)번 줄 · 놓으면 이동 / Esc 취소"
    }

    func previewMagneticPosition(time: Double, string: Int, screenX: Double, anchors: [NoteMagnetAnchor], shift: Bool) {
        guard canEdit else { return }
        guard time.isFinite, let dragged = positionDrag else { return }
        let candidates = anchors.compactMap { anchor -> NoteMagnetAnchor? in
            guard anchor.id != dragged.id,
                  let actual = project.events.first(where: { $0.id == anchor.id && $0.lane == dragged.lane }) else { return nil }
            return NoteMagnetAnchor(id: actual.id, time: actual.time, x: anchor.x)
        }
        applyMagnet(MagnetDragInput(time: time, string: string, screenX: screenX, anchors: candidates), shift: shift)
    }
    func updatePositionModifiers(shift: Bool) {
        guard canEdit else { return }
        guard positionDrag != nil, let input = magnetDragInput else { return }
        applyMagnet(input, shift: shift)
    }
    private func applyMagnet(_ input: MagnetDragInput, shift: Bool) {
        let anchor = shift ? NoteTimeMagnet.nearest(to: input.screenX, anchors: input.anchors) : nil
        // Dragging stays free; Shift alone requests alignment with another note.
        previewPositionDrag(time: anchor?.time ?? input.time, string: input.string, snap: false)
        magnetDragInput = input; positionMagnetTargetID = anchor?.id
        if let anchor {
            status = "Shift 마그넷 · \(String(format: "%.3f", anchor.time))초에 붙음 · Shift를 놓으면 자유 이동"
        }
    }
    func commitPositionDrag() {
        guard canEdit else { return }
        guard let preview = positionDrag, let index = project.events.firstIndex(where: { $0.id == preview.id }) else {
            positionDrag = nil; positionMagnetTargetID = nil; magnetDragInput = nil; return
        }
        positionDrag = nil; positionMagnetTargetID = nil; magnetDragInput = nil
        guard project.events[index].time != preview.time || project.events[index].string != preview.string else {
            status = "\(String(format: "%.3f", preview.time))초 · 숫자를 끌어서 위치 이동"
            return
        }
        var candidate = project
        candidate.events[index].time = preview.time
        candidate.events[index].string = preview.string
        guard (try? candidate.validated()) != nil else { return }
        recordUndo()
        project = candidate
        activeString = preview.string
        changed(); requestKeyboardFocus?()
        status = "\(String(format: "%.3f", preview.time))초로 이동 · ⌘Z 취소 · Shift+Space로 듣기"
    }
    func cancelPositionDrag() {
        guard canEdit else { return }
        positionDrag = nil; positionMagnetTargetID = nil; magnetDragInput = nil
        status = "이동 취소 · 선택 유지 · Esc를 다시 누르면 선택 해제"
        requestKeyboardFocus?()
    }
    func moveSelectedPosition(to time: Double, string: Int? = nil) {
        guard canMutateNotes, let selected, time.isFinite else { return }
        beginPositionDrag(selected)
        previewPositionDrag(time: time, string: string ?? selected.string, snap: false)
        commitPositionDrag()
    }
    func revealSelectedPosition() {
        guard let selected else { return }
        if scoreView { scorePage = scoreLayout.page(at: selected.time) }
        else if selected.time < windowStart || selected.time >= windowEnd {
            windowStart = min(max(0, selected.time - windowLength / 2), max(0, project.duration - windowLength))
        }
    }
    func focusSelectedForPosition() {
        guard canMutateNotes, let selected else { return }
        windowLength = min(project.duration, 2)
        windowStart = min(max(0, selected.time - windowLength / 2), max(0, project.duration - windowLength))
        scoreView = false; requestKeyboardFocus?()
        status = "음 주변 2초 확대 · 숫자를 드래그해서 위치 조절"
    }
    func zoomPositionWindow(by factor: Double) {
        let center = selected?.time ?? cursor
        windowLength = min(project.duration, min(48, max(0.25, windowLength * factor)))
        windowStart = min(max(0, center - windowLength / 2), max(0, project.duration - windowLength))
    }
    func auditionSelected() {
        guard canEdit else { return }
        guard let selected else { return }
        seek(selected.time)
        if !playing { togglePlayback() }
    }
    func deleteSelected() {
        guard canMutateNotes else { return }
        guard selected != nil else { return }
        recordUndo()
        project.events.removeAll { $0.id == selectedID }; selectedID = nil
        fretEntry.reset(); newlyCreatedID = nil; changed()
        requestKeyboardFocus?(); status = "메모 삭제 · ⌘Z로 되돌리기"
    }

    func moveSelectedString(by delta: Int) {
        guard canMutateNotes else { return }
        guard let selected else {
            activeString = min(6, max(1, activeString + delta))
            status = "편집 줄 \(activeString)번 · 숫자를 입력하면 현재 위치에 기록"
            return
        }
        let string = min(6, max(1, selected.string + delta))
        guard string != selected.string else { return }
        updateSelected { $0.string = string }
        activeString = string
        status = "\(string)번 줄 · \(selected.fret.map(String.init) ?? "?")프렛"
    }
    func nudgeSelectedTime(by delta: Double) {
        guard canMutateNotes else { return }
        guard delta.isFinite else { return }
        guard let selected else {
            if let time = TimeBounds.clamp(cursor + delta, duration: project.duration) { seekForEditing(time) }
            return
        }
        guard let time = TimeBounds.clamp(selected.time + delta, duration: project.duration) else { return }
        guard time != selected.time else { return }
        moveSelectedPosition(to: time); revealSelectedPosition()
        status = "위치 \(clockLabel(time)) · Shift+화살표로 정밀 이동"
    }
    func selectAdjacentEvent(backwards: Bool = false) {
        guard canMutateNotes else { return }
        let events = project.events.filter { $0.lane == lane }.sorted {
            $0.time == $1.time ? $0.string < $1.string : $0.time < $1.time
        }
        guard !events.isEmpty else { return }
        if let index = events.firstIndex(where: { $0.id == selectedID }) {
            let target = min(events.count - 1, max(0, index + (backwards ? -1 : 1)))
            select(events[target])
        } else if let event = backwards ? events.last(where: { $0.time <= cursor }) : events.first(where: { $0.time >= cursor }) {
            select(event)
        }
    }
    func markUnknown() {
        guard canMutateNotes else { return }
        if selectedID == nil {
            addEvent(time: cursor, string: activeString, matchingExisting: false)
            finishEntry(); selectedID = nil // The next explicit arrow starts another sparse note.
        } else { updateSelected { $0.fret = nil } }
    }
    func toggleTentative() { updateSelected { $0.tentative.toggle() } }
    func finishEntry() { guard canMutateNotes else { return }; fretEntry.reset(); newlyCreatedID = nil }
    func clearSelection() {
        guard canEdit else { return }
        if positionDrag != nil { cancelPositionDrag(); return }
        finishEntry(); selectedID = nil; requestKeyboardFocus?()
        status = "선택 해제 · 현재 위치에서 숫자로 입력"
    }

    /// The field's rounded display is not an edit. Stale controls cannot apply text to another UUID.
    @discardableResult
    func applyPositionTimeInput(_ text: String, displayed: String, eventID: UUID) -> Bool {
        guard canMutateNotes, let selected, selected.id == eventID, text != displayed,
              let parsed = Double(text.replacingOccurrences(of: ",", with: ".")),
              let time = TimeBounds.clamp(parsed, duration: project.duration), time != selected.time else { return false }
        moveSelectedPosition(to: time); revealSelectedPosition()
        return true
    }

    @discardableResult
    func setEntryInterval(_ seconds: Double) -> Bool {
        guard seconds.isFinite, seconds > 0, seconds <= 3600 else { return false }
        entryInterval = seconds; return true
    }
    func advanceEntry() {
        guard canMutateNotes, let time = TimeBounds.clamp(cursor + entryInterval, duration: project.duration) else { return }
        finishEntry(); seekForEditing(time)
        status = "다음 위치 \(clockLabel(cursor)) · 숫자 또는 ?로 입력"
    }
    func beginMemoEditing(eventID: UUID) {
        guard canMutateNotes, selectedID == eventID else { return }
        if memoSession?.eventID == eventID, memoSession?.projectID == projectIdentity { return }
        endMemoEditing()
        memoSession = MemoSession(projectID: projectIdentity, eventID: eventID, baseline: project.events)
    }
    func endMemoEditing(eventID: UUID? = nil) {
        if let eventID, memoSession?.eventID != eventID { return }
        memoSession = nil
    }
    func setMemo(_ text: String, eventID: UUID) {
        guard canMutateNotes, selectedID == eventID else { return }
        if memoSession == nil { beginMemoEditing(eventID: eventID) }
        applySelected({ $0.memo = text }, coalescingMemo: memoSession?.eventID == eventID)
    }

    @discardableResult
    private func recordUndo(coalescingMemo: Bool = false) -> UUID {
        if !coalescingMemo { endMemoEditing() }
        let snapshot = EditSnapshot(events: project.events, selectedID: selectedID, activeString: activeString)
        undoHistory.append(snapshot)
        if undoHistory.count > 100 { undoHistory.removeFirst() }
        redoHistory.removeAll()
        return snapshot.id
    }
    func undoEdit() {
        guard canEdit else { return }
        if positionDrag != nil { cancelPositionDrag(); return }
        endMemoEditing()
        guard let snapshot = undoHistory.popLast() else { return }
        redoHistory.append(EditSnapshot(events: project.events, selectedID: selectedID, activeString: activeString))
        restore(snapshot); status = "입력 취소 · ⇧⌘Z로 다시 실행"
    }
    func redoEdit() {
        guard canMutateNotes else { return }
        endMemoEditing()
        guard let snapshot = redoHistory.popLast() else { return }
        undoHistory.append(EditSnapshot(events: project.events, selectedID: selectedID, activeString: activeString))
        restore(snapshot); status = "입력 다시 실행"
    }
    private func restore(_ snapshot: EditSnapshot) {
        positionDrag = nil; positionMagnetTargetID = nil; magnetDragInput = nil
        project.events = snapshot.events; selectedID = snapshot.selectedID; activeString = snapshot.activeString
        fretEntry.reset(); newlyCreatedID = nil
        if let selected { lane = selected.lane; jumpToScoreTime(selected.time) }
        changed(); requestKeyboardFocus?()
    }
    private func changed() {
        projectRevision &+= 1
        refreshSaveState()
        scheduleAutosave()
    }
    private func refreshSaveState() {
        dirty = savedProject.map { project != $0 } ?? true
        saveState = dirty ? (projectURL == nil ? .unsaved : .pending) : (projectURL == nil ? .unsaved : .saved)
    }
    /// Await the currently scheduled revision; callers still inspect durable bytes and dirty state.
    func awaitAutosave() async { await autosaveTask?.value }

    private func scheduleAutosave() {
        autosaveTask?.cancel(); autosaveTask = nil
        guard !closed, dirty, let url = projectURL else { return }
        let identity = projectIdentity, revision = projectRevision
        autosaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            guard let self, !Task.isCancelled, !self.closed,
                  self.projectIdentity == identity, self.projectRevision == revision,
                  self.projectURL == url, self.dirty else { return }
            // A load pauses saving; its completion/cancellation always resumes the retained revision.
            guard self.canEdit else { return }
            _ = self.save(to: url)
        }
    }

    @discardableResult
    func analyze() -> Task<Void, Never>? {
        guard canEdit, let prepared, !analyzing else { return nil }
        let target = source, identityID = projectIdentity, duration = project.duration
        let id = UUID()
        analysisID = id
        analyzing = true; status = "\(target.title) 분석 중…"
        analysisTask = Task {
            defer {
                if analysisID == id { analyzing = false; analysisTask = nil; analysisID = nil }
            }
            do {
                let summary = try await services.analyze(prepared.url(for: target), duration)
                try Task.checkCancellation()
                guard !closed, analysisID == id, projectIdentity == identityID,
                      self.prepared?.directory == prepared.directory else { return }
                if let identity = prepared.identity {
                    let fingerprint = try await AudioPreparation.fingerprint(prepared.original)
                    try Task.checkCancellation()
                    guard !closed, analysisID == id, projectIdentity == identityID,
                          fingerprint == identity.sha256 else { throw AudioIssue.unsupported }
                }
                var attributed = summary
                if let asset = project.originalAsset, let identity = prepared.identity, asset.identity == identity {
                    attributed.provenance = AnalysisProvenance(assetID: asset.id, identity: identity,
                        channel: target.rawValue, analyzerVersion: services.analyzerVersion)
                }
                var candidate = project
                candidate.analyses[target.rawValue] = attributed
                project = try candidate.validated(); changed()
                status = "\(target.title) 분석 완료 · TAB은 직접 입력"
            } catch {
                guard !closed, analysisID == id else { return }
                if error is CancellationError || Task.isCancelled { status = "분석 취소됨" }
                else { self.error = error.localizedDescription; status = "분석 실패 · 편집은 계속할 수 있습니다" }
            }
        }
        return analysisTask
    }
    func cancelAnalysis() {
        analysisTask?.cancel(); analysisTask = nil; analysisID = nil; analyzing = false
        if !closed { status = "분석 취소됨" }
    }

    func importAudio(relink: Bool = false) {
        guard canLoad, relink || confirmDiscard(), let operation = reserveLoad() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false
        panel.message = relink ? "현재 TAB에 연결할 오디오를 선택하세요." : "채보할 원곡 또는 이미 분리한 기타 스템을 선택하세요."
        guard panel.runModal() == .OK, let url = panel.url else {
            if loadOperation?.id == operation.id { cancelLoading() }
            return
        }
        launchLoad(.audio(url, relink), operation: operation)
    }

    /// URL entry points share reservation/authorization with the panel and startup paths.
    @discardableResult
    func loadAudio(at url: URL, relink: Bool = false) -> Task<Bool, Never>? {
        guard canLoad, relink || confirmDiscard(), let operation = reserveLoad() else { return nil }
        return launchLoad(.audio(url, relink), operation: operation)
    }

    @discardableResult
    func loadDemo(long: Bool = false) -> Task<Bool, Never>? {
        guard canLoad, confirmDiscard(), let operation = reserveLoad() else { return nil }
        return launchLoad(.demo(long), operation: operation)
    }

    private func reserveLoad() -> LoadOperation? {
        guard !closed, !analyzing, loadOperation == nil, !busy || startupPending else { return nil }
        cancelPositionDrag(); endMemoEditing()
        let operation = LoadOperation(projectID: projectIdentity, snapshot: project)
        startupPending = false
        loadOperation = operation
        autosaveTask?.cancel()
        busy = true; loadProgress = 0; status = "오디오와 L/R 파형 준비 중…"
        return operation
    }

    @discardableResult
    private func launchLoad(_ request: LoadRequest, operation: LoadOperation) -> Task<Bool, Never>? {
        guard !closed, loadOperation?.id == operation.id else { return nil }
        let task = Task { await performLoad(request, operation: operation) }
        loadTask = task
        return task
    }

    /// A cancelled service may still finish. Its token cannot commit, publish or clear a newer busy state.
    func cancelLoading() {
        guard loadOperation != nil else { return }
        loadTask?.cancel(); loadTask = nil; loadOperation = nil
        busy = false; loadProgress = 0
        if !closed { status = "오디오 준비 취소됨 · 이전 작업 유지"; scheduleAutosave() }
    }

    private func requireCurrent(_ operation: LoadOperation) throws {
        try Task.checkCancellation()
        guard !closed, loadOperation?.id == operation.id,
              projectIdentity == operation.projectID, project == operation.snapshot else { throw CancellationError() }
    }

    private func publishProgress(_ value: Double, operation: LoadOperation) {
        guard !closed, loadOperation?.id == operation.id, value.isFinite else { return }
        loadProgress = max(loadProgress, min(1, max(0, value)))
    }

    private func stageAudio(_ url: URL, preserving: ScoreProject?, operation: LoadOperation) async throws -> StagedWorkspace {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let audio = try await services.prepare(url) { [weak self] progress in
            await self?.publishProgress(progress, operation: operation)
        }
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: audio.directory) } }
        try requireCurrent(operation)
        if let preserving, preserving.events.contains(where: { $0.time >= audio.duration }) { throw ProjectError.invalidData }
        let base = preserving ?? ScoreProject(title: url.deletingPathExtension().lastPathComponent, duration: audio.duration)
        let candidate = try base.relinkingOriginal(path: url.path, identity: audio.identity, duration: audio.duration)
        retained = true
        return StagedWorkspace(project: candidate, audio: audio,
            projectURL: preserving == nil ? nil : projectURL, baseline: preserving == nil ? nil : savedProject,
            status: audio.isMono ? "모노 파일 · L/R에는 같은 소리가 들어 있습니다" : "스테레오 준비 완료 · 채널별로 듣고 필요한 음을 남기세요")
    }

    private func stageProject(_ url: URL, operation: LoadOperation) async throws -> StagedWorkspace {
        let loaded = try await services.readProject(url).validated()
        try requireCurrent(operation)
        var staged: StagedWorkspace
        if let path = loaded.audioPath, services.fileExists(URL(fileURLWithPath: path)) {
            do {
                staged = try await stageAudio(URL(fileURLWithPath: path), preserving: loaded, operation: operation)
            } catch {
                try requireCurrent(operation)
                let fingerprint = try? await AudioPreparation.fingerprint(URL(fileURLWithPath: path))
                try requireCurrent(operation)
                staged = StagedWorkspace(project: loaded.invalidatingUnverifiedAnalysis(fingerprint: fingerprint), status: "오디오를 열지 못했습니다 · TAB은 오프라인으로 편집할 수 있습니다",
                    offlineReason: error.localizedDescription)
            }
        } else {
            staged = StagedWorkspace(project: loaded.invalidatingUnverifiedAnalysis(fingerprint: nil), status: "오디오 경로를 찾을 수 없습니다 · TAB은 오프라인으로 편집할 수 있습니다",
                offlineReason: "연결된 오디오를 찾을 수 없습니다")
        }
        staged.projectURL = url; staged.fromDisk = true; staged.baseline = loaded
        return staged
    }

    private func stageDemo(_ long: Bool, operation: LoadOperation) async throws -> StagedWorkspace {
        let demoProject = long ? ScoreProject.longDemo : .demo
        let url = try await services.createDemo(demoProject)
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: url) } }
        try requireCurrent(operation)
        var staged = try await stageAudio(url, preserving: demoProject, operation: operation)
        staged.projectURL = nil; staged.demoURL = url; staged.isDemo = true
        staged.baseline = staged.project // An untouched built-in example is not a user edit.
        staged.status = "합성 오디오 + 수동 TAB 예시 · 자동 채보 결과가 아닙니다"
        retained = true
        return staged
    }

    private func performLoad(_ request: LoadRequest, operation: LoadOperation) async -> Bool {
        var staged: StagedWorkspace?
        var committed = false
        defer {
            if !committed {
                if let audio = staged?.audio { try? FileManager.default.removeItem(at: audio.directory) }
                if let url = staged?.demoURL { try? FileManager.default.removeItem(at: url) }
            }
            if loadOperation?.id == operation.id {
                loadTask = nil; loadOperation = nil; busy = false
                if !closed { scheduleAutosave() }
            }
        }
        do {
            try requireCurrent(operation)
            switch request {
            case .startup:
                if let url = services.lastProject(), services.fileExists(url) {
                    do { staged = try await stageProject(url, operation: operation) }
                    catch {
                        try requireCurrent(operation)
                        staged = try await stageDemo(false, operation: operation)
                    }
                } else { staged = try await stageDemo(false, operation: operation) }
            case .demo(let long): staged = try await stageDemo(long, operation: operation)
            case .audio(let url, let relink):
                staged = try await stageAudio(url, preserving: relink ? operation.snapshot : nil, operation: operation)
            case .project(let url): staged = try await stageProject(url, operation: operation)
            }
            guard var candidate = staged else { return false }
            try requireCurrent(operation)
            let stagedPlayer: (any AudioPlayerTransport)?
            do {
                let readyPlayer = try preparePlayer(for: candidate)
                if let audio = candidate.audio, let identity = audio.identity {
                    guard try await AudioPreparation.fingerprint(audio.original) == identity.sha256
                    else { throw AudioIssue.sourceChanged }
                }
                stagedPlayer = readyPlayer
            }
            catch {
                try requireCurrent(operation)
                guard candidate.fromDisk, let decoded = candidate.baseline else { throw error }
                // Playback may fail because readable bytes changed after the decoder's final hash.
                // Recheck the current source, not the earlier PreparedAudio snapshot.
                var fingerprint: String?
                if let original = candidate.audio?.original {
                    fingerprint = try? await AudioPreparation.fingerprint(original)
                }
                try requireCurrent(operation)
                if let audio = candidate.audio { try? FileManager.default.removeItem(at: audio.directory) }
                candidate.project = decoded.invalidatingUnverifiedAnalysis(fingerprint: fingerprint)
                candidate.audio = nil
                candidate.offlineReason = error.localizedDescription
                candidate.status = "오디오를 열지 못했습니다 · TAB은 오프라인으로 편집할 수 있습니다"
                staged = candidate; stagedPlayer = nil
            }
            // Player initialization can fail or reenter through an injected service.
            // Recheck ownership only after all fallible work and before touching old state.
            try requireCurrent(operation)
            activate(candidate, player: stagedPlayer)
            committed = true; loadProgress = 1
            return true
        } catch {
            guard !closed, loadOperation?.id == operation.id else { return false }
            if error is CancellationError || Task.isCancelled { status = "오디오 준비 취소됨 · 이전 작업 유지" }
            else { self.error = error.localizedDescription; status = "오디오를 열지 못했습니다 · 이전 작업 유지" }
            return false
        }
    }

    private func preparePlayer(for staged: StagedWorkspace) throws -> (any AudioPlayerTransport)? {
        guard let audio = staged.audio else { return nil }
        let candidate = try services.makePlayer(audio.url(for: .stereo))
        candidate.enableRate = true; candidate.rate = rate
        candidate.currentTime = staged.isDemo ? 2 : 0
        guard candidate.prepareToPlay() else { throw AudioIssue.unsupported }
        return candidate
    }

    private func activate(_ staged: StagedWorkspace, player stagedPlayer: (any AudioPlayerTransport)?) {
        stopAndCleanAudio()
        let previousDemo = demoURL
        if let previousDemo, previousDemo != staged.audio?.original {
            try? FileManager.default.removeItem(at: previousDemo)
        }
        demoURL = staged.demoURL ?? (previousDemo == staged.audio?.original ? previousDemo : nil)
        prepared = staged.audio; project = staged.project
        audioConnection = staged.offlineReason.map { "오프라인 · " + $0 } ??
            (staged.audio?.isMono == true ? "모노 연결됨 · L/R 동일" : "스테레오 연결됨 · 원본 L/R")
        projectIdentity = UUID(); projectURL = staged.projectURL; isDemo = staged.isDemo
        selectedID = nil; cursor = staged.isDemo ? 2 : 0; windowStart = 0
        positionDrag = nil; positionMagnetTargetID = nil; magnetDragInput = nil
        memoSession = nil
        undoHistory.removeAll(); redoHistory.removeAll(); fretEntry.reset(); newlyCreatedID = nil
        inspectorVisible = false; scorePage = 0; followScore = true
        loopStart = staged.isDemo ? 2 : 0; loopEnd = staged.isDemo ? 6 : min(project.duration, 4)
        looping = false; source = .stereo
        player = stagedPlayer
        if let stagedPlayer { preparedPlayers[.stereo] = PreparedPlayer(transport: stagedPlayer, volume: stagedPlayer.volume) }
        projectRevision &+= 1
        savedProject = staged.baseline
        refreshSaveState()
        if staged.fromDisk, let url = projectURL { services.rememberProject(url) }
        status = staged.status; requestKeyboardFocus?()
    }

    func save() {
        // Dirty projects with a location resume autosave when the transition releases its reservation.
        guard canEdit else { return }
        let identity = projectIdentity
        let destination = projectURL ?? services.chooseSaveDestination(project.title)
        guard !closed, projectIdentity == identity else { return }
        guard let destination else {
            if dirty { saveState = .cancelled }
            return
        }
        if save(to: destination) { status = "프로젝트 저장 완료 · 이후 입력은 자동 저장" }
    }

    /// URL seam shares the same atomic save transaction as the panel and autosave paths.
    @discardableResult
    func save(to destination: URL) -> Bool {
        guard canEdit else { return false }
        autosaveTask?.cancel(); autosaveTask = nil
        let identity = projectIdentity, revision = projectRevision
        let snapshot = project
        var copiedAudio: URL?
        saveState = .saving
        do {
            var saved = try snapshot.validated()
            if isDemo, let audio = prepared, saved.audioPath == demoURL?.path {
                let copy = destination.deletingLastPathComponent().appendingPathComponent("RoughScore-demo-" + UUID().uuidString + ".wav")
                try FileManager.default.copyItem(at: audio.original, to: copy)
                copiedAudio = copy; saved.audioPath = copy.path
                if let index = saved.assets?.firstIndex(where: { $0.role == .original }) {
                    saved.assets?[index].reference = AudioReference(path: copy.path)
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try services.writeProject(encoder.encode(saved), destination)
            guard !closed, projectIdentity == identity else { return false }
            // Reentrant injected services cannot make a newer revision falsely clean.
            if projectRevision == revision, project == snapshot { project = saved }
            savedProject = saved; projectURL = destination
            refreshSaveState()
            services.rememberProject(destination)
            if dirty { scheduleAutosave() }
            return true
        } catch {
            if let copiedAudio { try? FileManager.default.removeItem(at: copiedAudio) }
            guard !closed, projectIdentity == identity else { return false }
            dirty = savedProject.map { project != $0 } ?? true
            saveState = .failed; self.error = error.localizedDescription
            return false
        }
    }

    func openProject() {
        guard canLoad, confirmDiscard(), let operation = reserveLoad() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "roughscore") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else {
            if loadOperation?.id == operation.id { cancelLoading() }
            return
        }
        launchLoad(.project(url), operation: operation)
    }

    @discardableResult
    func loadProject(at url: URL) -> Task<Bool, Never>? {
        guard canLoad, confirmDiscard(), let operation = reserveLoad() else { return nil }
        return launchLoad(.project(url), operation: operation)
    }

    func exportText() {
        guard canEdit else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = project.title + "-TAB.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let formatter = { (time: Double) in String(format: "%.3f", time) }
        var text = "RoughScore — \(project.title)\nStandard tuning: E B G D A E (1 → 6)\n? = 음 미확인 / 미기록 구간은 쉼표가 아닙니다\n\n"
        for lane in GuitarLane.allCases {
            text += "[\(lane.title)]\n시간(초)\t줄\t프렛\t음표 길이\t표시\t메모\n"
            for event in project.events.filter({ $0.lane == lane }).sorted(by: { $0.time < $1.time }) {
                text += "\(formatter(event.time))\t\(event.string)\t\(event.fret.map(String.init) ?? "?")\t\(event.length?.title ?? "미지정")\t\(event.tentative ? "잠정" : "수동")\t\(event.memo.replacingOccurrences(of: "\n", with: " "))\n"
            }
            text += "\n"
        }
        do { try text.write(to: url, atomically: true, encoding: .utf8); status = "시간 기반 TAB 텍스트 내보내기 완료" }
        catch { self.error = error.localizedDescription }
    }

    func confirmDiscard() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "저장하지 않은 TAB 변경 사항이 있습니다."
        alert.informativeText = "저장한 뒤 계속하거나, 변경 사항을 버릴 수 있습니다."
        alert.addButton(withTitle: "저장하고 계속"); alert.addButton(withTitle: "취소"); alert.addButton(withTitle: "변경 버리기")
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(); return !dirty
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func stopAndCleanAudio() {
        for cached in preparedPlayers.values { cached.transport.stop() }
        preparedPlayers.removeAll(); scheduledStart = nil
        player?.stop(); player = nil; playing = false
        if let prepared { try? FileManager.default.removeItem(at: prepared.directory) }
        prepared = nil
    }
    func shutdown() {
        guard !closed else { return }
        closed = true; startupPending = false
        nativeTextObserver?.cancel(); nativeTextObserver = nil; memoSession = nil
        cancelLoading(); cancelAnalysis()
        busy = false
        autosaveTask?.cancel()
        analysisTask?.cancel(); timer?.invalidate(); stopAndCleanAudio()
        if let demoURL { try? FileManager.default.removeItem(at: demoURL) }
    }
}
