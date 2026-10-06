import AppKit
import AVFoundation
import Combine
import RoughScoreCore
import UniformTypeIdentifiers

@MainActor
final class Workspace: ObservableObject {
    @Published var project = ScoreProject.demo {
        didSet {
            if oldValue != project { modelGeneration &+= 1 }
            if oldValue.tuning != project.tuning || oldValue.tuningDefinition != project.tuningDefinition ||
                oldValue.duration != project.duration || oldValue.events.first(where: { $0.id == selectedID }) != selected {
                clearPitchDetection()
            }
            pruneSelection()
        }
    }
    @Published var prepared: PreparedAudio? {
        didSet {
            if oldValue?.generation != prepared?.generation {
                clearPitchDetection()
            }
        }
    }
    @Published private(set) var audioConnection = "오디오 준비 전"
    @Published private(set) var assetRole: AudioAsset.Role = .original { didSet { sessionChanged() } }
    @Published private(set) var stemConnection = "스템 없음"
    private var originalAudio: PreparedAudio?
    private var stemAudio: PreparedAudio?
    private var inactivePlayers: [ListeningSource: PreparedPlayer] = [:]
    @Published var source: ListeningSource = .stereo { didSet { if source != oldValue { clearPitchDetection(); sessionChanged() } } }
    @Published var lane: GuitarLane = .left { didSet { if lane != oldValue { clearPitchDetection(); sessionChanged() } } }
    @Published var activeString = 6
    @Published var selectedID: UUID? { didSet { if selectedID != oldValue { clearPitchDetection() } } }
    @Published private(set) var selection = try! TabSelection()
    @Published private(set) var selectionRange: TimeSpan?
    var selectedIDs: Set<UUID> {
        selection.ids.union(selectedID.map { [$0] } ?? [])
    }
    var editSelection: TabSelection {
        try! TabSelection(ids: selectedIDs, primaryID: selectedID ?? selection.primaryID)
    }
    var canEditSelection: Bool { canMutateNotes && !selectedIDs.isEmpty }
    var canUseTabClipboard: Bool { canMutateNotes && services.nativeTextUndo() == nil }
    private var dragSelection: TabSelection?
    private var dragEvents: [TabEvent]?
    @Published var cursor = 2.0 { didSet { if cursor != oldValue { clearPitchDetection(); sessionChanged() } } }
    @Published private(set) var entryInterval = 0.05
    @Published var windowStart = 0.0 { didSet { sessionChanged() } }
    @Published var windowLength = 12.0 { didSet { sessionChanged() } }
    @Published var loopStart = 2.0 { didSet { sessionChanged() } }
    @Published var loopEnd = 6.0 { didSet { sessionChanged() } }
    @Published var looping = false { didSet { sessionChanged() } }
    @Published var playing = false
    @Published var rate: Float = 1 { didSet { if rate != oldValue { updatePlaybackRate(); sessionChanged() } } }
    @Published var showLengths = false { didSet { sessionChanged() } }
    @Published var snapToBeat = false { didSet { sessionChanged() } }
    @Published private(set) var busy = false
    @Published private(set) var loadProgress = 0.0
    @Published var analyzing = false
    /// Transient review list, never saved. Only an explicit accept turns a row into TAB.
    @Published private(set) var pitchProposals: [PitchProposal] = []
    /// The L/R lane whose channel produced `pitchProposals`.
    private(set) var proposalLane: GuitarLane = .left
    @Published var status = "데모 준비 중"
    @Published var error: String?
    // Separate, nonmodal feedback cannot overwrite a save/load error or nest an NSAlert.
    @Published var externalOpenError: String?
    @Published private(set) var exportSnapshot: ScoreExportSnapshot?
    @Published private(set) var exportBusy = false
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
    @Published var scoreView = true { didSet { sessionChanged() } }
    @Published var measuresPerSystem = 4 { didSet { sessionChanged() } }
    @Published var scorePage = 0 { didSet { sessionChanged() } }
    @Published var showBothLanes = false { didSet { sessionChanged() } }
    @Published var showScoreWaveforms = true { didSet { sessionChanged() } }
    @Published var followScore = true { didSet { sessionChanged() } }
    @Published var inspectorVisible = false
    @Published private(set) var positionDrag: TabEvent?
    @Published private(set) var positionMagnetTargetID: UUID?
    @Published private(set) var detectedPitch: DetectedPitch?
    @Published private(set) var detectingPitch = false
    @Published private(set) var pitchDetectionMessage = ""
    private var pitchTask: Task<Void, Never>?
    private var pitchRequestID: UUID?
    private struct SelectedPitchContext: Equatable {
        let projectID: UUID
        let event: TabEvent
        let generation: UUID
        let audioURL: URL
        let source: ListeningSource
        let lane: GuitarLane
        let cursor: Double
        let duration: Double
        let tuning: [String]
        let tuningDefinition: TuningDefinition?
    }
    private var selectedPitchContext: SelectedPitchContext? {
        guard let event = selected, let audio = prepared else { return nil }
        return SelectedPitchContext(projectID: projectIdentity, event: event, generation: audio.generation,
            audioURL: event.lane == .left ? audio.left : audio.right, source: source, lane: lane, cursor: cursor,
            duration: project.duration, tuning: project.tuning, tuningDefinition: project.tuningDefinition)
    }
    private func ownsPitchRequest(_ id: UUID, context: SelectedPitchContext) -> Bool {
        !closed && !Task.isCancelled && pitchRequestID == id && selectedPitchContext == context
    }
    private struct MagnetDragInput {
        let time: Double
        let string: Int
        let screenX: Double
        let anchors: [NoteMagnetAnchor]
    }
    private var magnetDragInput: MagnetDragInput?
    var requestKeyboardFocus: (() -> Void)?
    var requestControlFocus: ((Bool) -> Bool)?
    var keyboardFocusOwner: UUID?
    var controlFocusOwner: UUID?
    var scoreDisplayOwner: UUID?
    var requestScoreFitPageToggle: (() -> Void)?
    @Published var tabInputFocused = false // Ephemeral; never saved or added to note history.
    private var fretEntry = FretEntryBuffer()
    private var newlyCreatedID: UUID?
    private struct StemState {
        let asset: AudioAsset
        let analyses: [String: AnalysisSummary]
        let audio: PreparedAudio
        let players: [ListeningSource: PreparedPlayer]
    }
    private struct EditSnapshot {
        let id = UUID()
        let events: [TabEvent]
        let selectedID: UUID?
        let selection: TabSelection
        let selectionRange: TimeSpan?
        let cursor: Double?
        let activeString: Int
        let tuning: [String]
        let tuningDefinition: TuningDefinition?
        var stemState: StemState? = nil
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
    @Published private(set) var sessionPersistenceError: String?
    private var sessionTask: Task<Void, Never>?
    private var restoringSession = false
    private var lastPersistedSession: WorkspaceSession?
    private var lastSessionURL: URL?
    private var lastSessionIdentity: String?
    private var autosaveTask: Task<Void, Never>?
    private var projectURL: URL?
    private var currentPackage: PortableProjectPackage.Snapshot?
    private var saveOperation: UUID?
    var activeProjectURL: URL? { projectURL }
    var currentPackageURL: URL? { currentPackage == nil ? nil : projectURL }
    var canSave: Bool { canEdit && saveOperation == nil }

    private var projectRevision: UInt64 = 0
    private var modelGeneration: UInt64 = 0
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
    private var assetHandoverTask: Task<Void, Never>?
    private var assetHandoverID: UUID?
    private var outgoingAssetPlayers: [ListeningSource: PreparedPlayer] = [:]
    private var outgoingAssetAudio: PreparedAudio?
    private var outgoingAssetRole: AudioAsset.Role?
    private var outgoingSource: ListeningSource?
    private var outgoingScheduledStart: ScheduledStart?
    private var preparedPlayers: [ListeningSource: PreparedPlayer] = [:]
    private var timer: Timer?
    private var analysisTask: Task<Void, Never>?
    private var demoURL: URL?
    private let services: WorkspaceServices
    private var startupPending: Bool
    private var started = false
    private var closed = false
    var isClosed: Bool { closed }
    var externalOpenDidShutdown: (() -> Void)?
    var externalOpenDidCancelLoad: (() -> Void)?
    private var automaticStartupOperationID: UUID?
    private var externalProjectOperationID: UUID?
    @Published private var projectIdentity = UUID()
    var editorIdentity: UUID { projectIdentity }
    private var loadTask: Task<Bool, Never>?
    private var loadOperation: LoadOperation?
    private var analysisID: UUID?

    private struct LoadOperation: Sendable {
        let id = UUID()
        let projectID: UUID
        let snapshot: ScoreProject
        let session: WorkspaceSession
    }
    private enum LoadRequest: Sendable {
        case startup, demo(Bool), audio(URL, Bool), project(URL)
    }
    private struct StagedWorkspace: Sendable {
        var project: ScoreProject
        var audio: PreparedAudio?
        var projectURL: URL?
        var package: PortableProjectPackage.Snapshot?
        var demoURL: URL?
        var isDemo = false
        var fromDisk = false
        var baseline: ScoreProject?
        var status: String
        var offlineReason: String?
        var stemAudio: PreparedAudio?
        var stemReason: String?
        var session: WorkspaceSession?
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
    var canLoad: Bool { canEdit && !analyzing && exportSnapshot == nil && !exportBusy }
    var canMutateNotes: Bool { canEdit && positionDrag == nil && exportSnapshot == nil && !exportBusy }
    var canExport: Bool { canEdit && positionDrag == nil && dragEvents == nil && exportSnapshot == nil && !exportBusy }


    var windowEnd: Double { min(project.duration, windowStart + windowLength) }
    var visibleEvents: [TabEvent] {
        project.events.filter { $0.lane == lane && $0.time >= windowStart && $0.time < windowEnd }
    }
    var selected: TabEvent? { project.events.first { $0.id == selectedID } }

    /// Atomic shared L/R settings change; existing manual positions never remap.
    @discardableResult
    func setTuning(openMIDIPitches: [Int], capo: Int) -> Bool {
        guard canMutateNotes else { return false }
        let definition = TuningDefinition(openMIDIPitches: openMIDIPitches, capo: capo)
        guard (try? definition.validated()) != nil else { return false }
        var candidate = project
        candidate.tuningDefinition = definition
        candidate.tuning = openMIDIPitches.map(TuningDefinition.pitchName)
        guard (try? candidate.validated()) != nil else { return false }
        if candidate == project { return true }
        recordUndo(preservingCursor: true); finishEntry(); project = candidate; changed()
        status = "튜닝/카포 적용 · L/R 공통 · 기존 줄/프렛 유지 · ⌘Z 취소"
        return true
    }

    func fingerings(midi: Int, preferredFret: Int? = nil, eventID: UUID) -> FingeringResolution {
        guard let event = selected, event.id == eventID else { return .invalidContext }
        return FingeringResolver.resolve(midi: midi, project: project, preferredFret: preferredFret,
            context: FingeringContext(lane: event.lane, time: event.time, excludingEventID: event.id))
    }

    /// Re-resolve stale controls against current tuning/selection; apply only the explicit choice.
    @discardableResult
    func chooseFingering(midi: Int, string: Int, fret: Int, eventID: UUID) -> Bool {
        guard canMutateNotes, let event = selected, event.id == eventID,
              fingerings(midi: midi, eventID: eventID).candidates.contains(where: { $0.string == string && $0.fret == fret })
        else { return false }
        if event.string == string && event.fret == fret { return true }
        updateSelected { $0.string = string; $0.fret = fret }
        status = "\(string)번 줄 / \(fret)프렛 선택 · ⌘Z로 한 번에 취소"
        return true
    }

    func clearPitchDetection() {
        pitchTask?.cancel(); pitchTask = nil; pitchRequestID = nil
        detectedPitch = nil; detectingPitch = false; pitchDetectionMessage = ""
    }

    /// Optional clean-monophonic estimate on the selected lane's prepared PCM; never edits TAB.
    @discardableResult
    func detectSelectedPitch() -> Task<Void, Never>? {
        guard canMutateNotes, let context = selectedPitchContext else { return nil }
        clearPitchDetection()
        let audio = prepared
        let id = UUID()
        pitchRequestID = id; detectingPitch = true
        let task = Task {
            defer { if pitchRequestID == id { detectingPitch = false; pitchTask = nil } }
            do {
                let access = try audio.map { try PreparedAudioFileAccess(resource: $0.resource, url: context.audioURL) }
                defer { withExtendedLifetime(access) {} }
                let result = try await services.detectPitch(access?.url ?? context.audioURL, context.event.time)
                try access?.validate()
                guard ownsPitchRequest(id, context: context) else { return }
                if let audio, let identity = audio.identity {
                    guard try await AudioPreparation.fingerprint(audio.original) == identity.sha256 else { throw AudioIssue.sourceChanged }
                }
                guard ownsPitchRequest(id, context: context) else { return }
                detectedPitch = result
                pitchDetectionMessage = result == nil ? "안정된 단음 음고 없음 · 직접 입력 가능" : "단음 추정 · 반음 반올림 · 운지는 직접 선택"
            } catch {
                guard ownsPitchRequest(id, context: context) else { return }
                pitchDetectionMessage = "음고 추정 불가 · 직접 MIDI 입력 가능"
            }
        }
        pitchTask = task
        return task
    }
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
    var activeAsset: AudioAsset? { assetRole == .original ? project.originalAsset : project.stemAsset }
    var summary: AnalysisSummary? { project.analyses[project.analysisKey(asset: activeAsset, channel: source)] }
    var scoreSummary: AnalysisSummary? {
        scoreSummary(in: project.analyses)
    }
    func scoreSummary(in analyses: [String: AnalysisSummary]) -> AnalysisSummary? {
        analyses[project.analysisKey(asset: activeAsset, channel: .stereo)] ??
            analyses[project.analysisKey(asset: activeAsset, channel: source)] ??
            analyses[project.analysisKey(asset: activeAsset, channel: .left)] ??
            analyses[project.analysisKey(asset: activeAsset, channel: .right)]
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
        startLifecycle()
        guard let operation = reserveLoad() else { return nil }
        automaticStartupOperationID = operation.id
        return launchLoad(.startup, operation: operation)
    }

    private func startLifecycle() {
        guard !started, !closed else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    enum ExternalProjectAdmission {
        case loading(Task<Bool, Never>), cancelled, rejected(String)
    }

    private struct ExternalAuthorization: Equatable {
        let identity: UUID
        let revision: UInt64
        let generation: UInt64
        let project: ScoreProject
        let url: URL?
        let dirty: Bool
    }
    private var externalAuthorization: ExternalAuthorization {
        .init(identity: projectIdentity, revision: projectRevision, generation: modelGeneration,
              project: project, url: projectURL, dirty: dirty)
    }
    // A receipt is captured by the ordinary writer before injected remember/session callbacks.
    // Only that exact committed save may rebase an external-open authorization.
    private struct ExternalSaveReceipt {
        let before: ExternalAuthorization
        let after: ExternalAuthorization
    }
    private var lastSaveReceipt: ExternalSaveReceipt?

    func admitExternalProject(at url: URL, ownsRequest: () -> Bool) -> ExternalProjectAdmission {
        let retry = "다른 작업이 진행 중입니다. 작업을 마친 뒤 프로젝트 열기를 다시 시도하세요."
        guard !closed, ownsRequest() else { return .rejected("종료된 작업 공간에서는 프로젝트를 열 수 없습니다.") }
        let starting = startupPending || (automaticStartupOperationID != nil && automaticStartupOperationID == loadOperation?.id)
        guard !analyzing, saveOperation == nil, exportSnapshot == nil, !exportBusy,
              !services.nativeModalActive(), starting || canLoad else { return .rejected(retry) }

        if !starting {
            let before = externalAuthorization
            var expected = before
            if dirty {
                let decision = services.discardDecision()
                // The native modal loop can mutate/replace/close the document or request owner.
                guard ownsRequest(), !closed, externalAuthorization == before, canLoad,
                      saveOperation == nil, !services.nativeModalActive() else { return .rejected(retry) }
                switch decision {
                case .cancel: return .cancelled
                case .discard: break
                case .saveAndContinue:
                    lastSaveReceipt = nil
                    save()
                    guard let receipt = lastSaveReceipt, !dirty else { return .cancelled }
                    guard receipt.before == before else { return .rejected(retry) }
                    expected = receipt.after
                }
            }
            guard ownsRequest(), !closed, externalAuthorization == expected, canLoad,
                  saveOperation == nil, !services.nativeModalActive() else { return .rejected(retry) }
        }
        guard ownsRequest(), !closed else { return .rejected(retry) }
        let authorized = externalAuthorization
        // Only the automatic startup operation may be superseded. No fallback is restarted.
        if automaticStartupOperationID != nil { cancelLoading() }
        startLifecycle()
        guard let operation = reserveLoad(requestFocus: false, authorizesReservation: {
            !self.services.nativeModalActive() && ownsRequest() && !self.closed &&
                self.externalAuthorization == authorized
        }), let task = launchLoad(.project(url), operation: operation) else {
            return .rejected(retry)
        }
        externalProjectOperationID = operation.id
        return .loading(task)
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

    func seekForEditing(_ time: Double, lane: GuitarLane? = nil, requestFocus: Bool = true) {
        guard canMutateNotes, let bounded = TimeBounds.clamp(time, duration: project.duration) else { return }
        endMemoEditing()
        clearPitchDetection()
        fretEntry.reset(); newlyCreatedID = nil; resetSelection()
        if let lane { selectLane(lane) }
        jumpToScoreTime(bounded); if requestFocus { requestKeyboardFocus?() }
        status = "\(clockLabel(cursor)) · \(activeString)번 줄에 숫자로 입력 · 파형 드래그로 반복"
    }
    func selectLane(_ value: GuitarLane) {
        guard canMutateNotes else { return }
        if value != lane { clearPitchDetection() }
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
        if let pending = scheduledStart, !outgoingAssetPlayers.isEmpty {
            if transport.deviceCurrentTime < pending.epoch, let audible = outgoingAssetPlayers[outgoingSource ?? source]?.transport {
                if let start = outgoingScheduledStart, audible.deviceCurrentTime < start.epoch { return start.position }
                return audible.currentTime
            }
            finishAssetHandover()
        }
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
        var outgoingPosition: Double?
        if let pending = scheduledStart, let audible = outgoingAssetPlayers[outgoingSource ?? source]?.transport,
           audible.deviceCurrentTime < pending.epoch {
            let start = outgoingScheduledStart
            audible.pause()
            outgoingPosition = start.map { audible.deviceCurrentTime < $0.epoch ? $0.position : audible.currentTime } ?? audible.currentTime
        }
        finishAssetHandover()
        let pending = scheduledStart
        let restoreAnchor = pending.map { pending in
            player.map { $0.deviceCurrentTime < pending.epoch || $0.currentTime < pending.position } ?? false
        } ?? false
        player?.pause()
        for cached in preparedPlayers.values where cached.transport !== player { cached.transport.pause() }
        if let position = outgoingPosition ?? (restoreAnchor ? pending?.position : nil) {
            setGroupPosition(preparedPlayers, to: position)
        }
        for (value, var cached) in preparedPlayers {
            cached.scheduledEpoch = nil; preparedPlayers[value] = cached
        }
        scheduledStart = nil
    }

    private func finishAssetHandover() {
        assetHandoverTask?.cancel(); assetHandoverTask = nil; assetHandoverID = nil
        for cached in outgoingAssetPlayers.values {
            cached.transport.volume = 0; cached.transport.pause()
        }
        outgoingAssetPlayers.removeAll()
        outgoingAssetAudio = nil; outgoingAssetRole = nil; outgoingSource = nil; outgoingScheduledStart = nil
        cleanRetiredStemCaches()
    }

    private func setGroupPosition(_ group: [ListeningSource: PreparedPlayer], to time: Double) {
        var clocks: Set<UUID> = []
        for cached in group.values {
            if let id = cached.transport.sharedClockID, !clocks.insert(id).inserted { continue }
            cached.transport.currentTime = time
        }
    }

    private func stopInactivePlayers() {
        for cached in inactivePlayers.values {
            let retained = outgoingAssetPlayers.values.contains {
                $0.transport === cached.transport || (cached.transport.sharedClockID != nil && $0.transport.sharedClockID == cached.transport.sharedClockID)
            }
            if !retained { cached.transport.stop() }
        }
    }

    private func cancelAssetHandoverReturningToOutgoing() {
        guard let audio = outgoingAssetAudio, let role = outgoingAssetRole,
              let audible = outgoingAssetPlayers[source]?.transport else { return }
        assetHandoverTask?.cancel(); assetHandoverTask = nil; assetHandoverID = nil
        preparedPlayers.values.forEach { $0.transport.volume = 0; $0.transport.pause() }
        let pendingGroup = preparedPlayers
        preparedPlayers = outgoingAssetPlayers; inactivePlayers = pendingGroup
        prepared = audio; assetRole = role; player = audible
        scheduledStart = outgoingScheduledStart
        outgoingAssetPlayers.removeAll(); outgoingAssetAudio = nil; outgoingAssetRole = nil; outgoingSource = nil; outgoingScheduledStart = nil
        for (channel, cached) in preparedPlayers { cached.transport.volume = channel == source ? cached.volume : 0 }
        cursor = boundedPlaybackTime(livePlayerTime(audible)); playing = audible.isPlaying
    }

    private func updatePlaybackRate() {
        if let audible = outgoingAssetPlayers[outgoingSource ?? source]?.transport, let pending = scheduledStart,
           audible.deviceCurrentTime < pending.epoch {
            let snapshot = audible.clockSnapshot(), now = audible.deviceCurrentTime, oldRate = audible.rate
            let reference = outgoingScheduledStart.map { PlaybackClockSnapshot(position: $0.position, deviceTime: $0.epoch) } ?? snapshot
            let elapsed = outgoingScheduledStart == nil ? now - reference.deviceTime : max(0, now - reference.deviceTime)
            let position = boundedPlaybackTime(reference.position + elapsed * Double(oldRate))
            outgoingAssetPlayers.values.forEach { $0.transport.rate = rate }
            guard let destination = player else { return }
            do {
                // Preserve the upstream native clock's phase, including already-prefetched input
                // frames, when changing the rate. A wall-time pivot would discard that phase.
                let start = try scheduleAssetGroup(preparedPlayers, destination: destination, reference: reference,
                                                   stationary: outgoingScheduledStart != nil, parked: position, resume: true)
                guard !closed, player === destination else { throw CancellationError() }
                scheduledStart = start
                for (channel, var cached) in preparedPlayers {
                    cached.scheduledEpoch = start.epoch; preparedPlayers[channel] = cached
                }
                destination.volume = preparedPlayers[source]!.volume
                armAssetHandover(epoch: start.epoch, destination: destination)
                cursor = boundedPlaybackTime(livePlayerTime(destination))
            } catch {
                let currentAudio = outgoingAssetRole == .original ? originalAudio : stemAudio
                if let outgoing = outgoingAssetAudio, outgoing.generation == currentAudio?.generation,
                   outgoingAssetPlayers[source]?.transport.isPlaying == true {
                    cancelAssetHandoverReturningToOutgoing()
                } else { pausePlayers(); playing = false }
                self.error = error.localizedDescription
            }
            return
        }
        if let player, player.sharedClockID != nil {
            player.rate = rate
            if playing { cursor = boundedPlaybackTime(livePlayerTime(player)) }
            return
        }
        let resume = playing
        pausePlayers()
        if resume, let player { cursor = boundedPlaybackTime(livePlayerTime(player)) }
        for cached in preparedPlayers.values where cached.transport.rate != rate { cached.transport.rate = rate }
        if resume { startPlayers(at: cursor) }
    }

    /// Prepare all IO muted, then reserve one original-song position on the native host clock.
    private func scheduleAssetGroup(_ group: [ListeningSource: PreparedPlayer], destination: any AudioPlayerTransport,
                                    reference: PlaybackClockSnapshot?, stationary: Bool, parked: Double,
                                    resume: Bool) throws -> ScheduledStart {
        var lead = 0.08
        for _ in 0..<3 {
            let preparingAt = destination.deviceCurrentTime
            let epoch = preparingAt + (resume ? lead : 0)
            var time = parked
            if resume, let reference {
                let elapsed = stationary ? max(0, epoch - reference.deviceTime) : epoch - reference.deviceTime
                time = boundedPlaybackTime(reference.position + elapsed * Double(rate))
            }
            var positioned: Set<UUID> = []
            for cached in group.values {
                cached.transport.volume = 0; cached.transport.rate = rate
                if let id = cached.transport.sharedClockID, !positioned.insert(id).inserted { continue }
                cached.transport.currentTime = time
                guard cached.transport.prepareToPlay() else { throw AudioIssue.playbackFailed }
            }
            if resume, destination.deviceCurrentTime >= epoch - 0.02 {
                lead = max(lead * 2, destination.deviceCurrentTime - preparingAt + 0.04)
                continue
            }
            for cached in group.values where resume {
                guard cached.transport.play(atTime: epoch), cached.transport.isPlaying else { throw AudioIssue.playbackFailed }
            }
            if resume, destination.deviceCurrentTime >= epoch - 0.002 {
                group.values.forEach { $0.transport.pause() }
                lead = max(lead * 2, destination.deviceCurrentTime - preparingAt + 0.04)
                continue
            }
            return ScheduledStart(epoch: epoch, position: time)
        }
        throw AudioIssue.playbackFailed
    }

    private func armAssetHandover(epoch: Double, destination: any AudioPlayerTransport) {
        assetHandoverTask?.cancel()
        let token = UUID(); assetHandoverID = token
        assetHandoverTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, epoch - destination.deviceCurrentTime))) }
            catch { return }
            guard let self, self.assetHandoverID == token else { return }
            self.finishAssetHandover()
        }
    }

    private func cachedPlayer(for value: ListeningSource, audio: PreparedAudio) throws -> PreparedPlayer {
        if let cached = preparedPlayers[value] { return cached }
        let identity = projectIdentity
        let transport = try services.makePlayer(audio, value)
        transport.enableRate = true; transport.rate = rate
        guard transport.prepareToPlay() else { throw AudioIssue.playbackFailed }
        guard canEdit, projectIdentity == identity, prepared?.generation == audio.generation else { throw CancellationError() }
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
        guard !closed, projectIdentity == identity, self.prepared?.generation == prepared.generation,
              self.player === player else { return }
        pausePlayers()
        var ready: [ListeningSource: PreparedPlayer] = [:]
        for (value, cached) in preparedPlayers {
            if cached.transport.rate != rate { cached.transport.rate = rate }
            cached.transport.currentTime = time
            cached.transport.volume = value == source ? cached.volume : 0
            if cached.transport.prepareToPlay() { ready[value] = cached }
        }
        guard ready[source] != nil else {
            playing = false; error = AudioIssue.playbackFailed.localizedDescription
            return
        }
        let epoch = player.deviceCurrentTime + 0.02
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
                let sameRenderClock = old?.sharedClockID != nil && old?.sharedClockID == destination.sharedClockID
                // A shared graph cannot resume or seek one failed source without disturbing the
                // running old source. Reject that destination while leaving the usable graph alone.
                if sameRenderClock && resume && !destination.isPlaying { throw AudioIssue.playbackFailed }
                let aligned = destination.isPlaying && (sameRenderClock || queuedAtAnchor ||
                    (destinationTime >= target + elapsedMinimum * Double(rate) - 0.015 &&
                     destinationTime <= target + elapsedMaximum * Double(rate) + 0.015))
                if resume && !aligned {
                    cached.scheduledEpoch = nil; preparedPlayers[value] = cached
                    destination.volume = 0
                    sampledTime = livePlayerTime(old)
                    liveTime = boundedPlaybackTime(sampledTime)
                    loopWrap = looping && sampledTime.isFinite && sampledTime >= loopEnd
                    destination.currentTime = loopWrap ? loopStart : liveTime
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
                } else {
                    // Native getters may wait for a render quantum. The coherent destination keeps
                    // advancing, so publish a fresh OLD live sample at the gain handover itself.
                    sampledTime = livePlayerTime(old)
                    liveTime = boundedPlaybackTime(sampledTime)
                    loopWrap = looping && sampledTime.isFinite && sampledTime >= loopEnd
                }
                if loopWrap && resume {
                    // A switch may observe the loop boundary before the 30ms tick. Re-anchor every
                    // channel together so subsequent switches retain the same loop clock.
                    startPlayers(at: loopStart)
                    guard destination.isPlaying else { throw AudioIssue.playbackFailed }
                }
                guard canMutateNotes, projectIdentity == identity,
                      self.prepared?.generation == prepared.generation else {
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
        source = value; pitchProposals = []
        if outgoingAssetPlayers[value]?.transport.isPlaying == true {
            outgoingSource = value
            for (channel, cached) in outgoingAssetPlayers { cached.transport.volume = channel == value ? cached.volume : 0 }
        }
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
        project.events.append(event); setSelection(try! TabSelection(ids: [event.id], primaryID: event.id)); dirty = true; jumpToScoreTime(actual)
        fretEntry.reset(); newlyCreatedID = event.id
        requestKeyboardFocus?(); changed()
        status = "숫자를 입력하세요 · 10–24는 이어서 입력 · Delete 삭제 / ⌘Z 취소"
    }

    func select(_ event: TabEvent) {
        guard canMutateNotes, let actual = project.events.first(where: { $0.id == event.id }) else { return }
        endMemoEditing()
        clearPitchDetection()
        fretEntry.reset(); newlyCreatedID = nil
        setSelection(try! TabSelection(ids: [actual.id], primaryID: actual.id)); activeString = actual.string; selectLane(actual.lane); jumpToScoreTime(actual.time)
        requestKeyboardFocus?()
        status = "숫자로 프렛 변경 · ↑↓ 줄 이동 · ←→ 위치 이동 · Tab 다음 음"
    }

    private func resetSelection() {
        clearPitchDetection()
        selectedID = nil; selection = try! TabSelection(); selectionRange = nil
    }
    private func setSelection(_ value: TabSelection, range: TimeSpan? = nil) {
        if selectedID != value.primaryID { clearPitchDetection() }
        selection = value; selectedID = value.primaryID; selectionRange = range
    }
    private func pruneSelection() {
        let available = Set(project.events.map(\.id))
        let ids = selection.ids.intersection(available)
        if let active = selectedID, !available.contains(active) { selectedID = nil }
        if ids != selection.ids {
            selection = try! TabSelection(ids: ids, primaryID: selectedID.flatMap { ids.contains($0) ? $0 : nil })
            selectionRange = nil
        }
    }
    func toggleSelection(_ event: TabEvent) {
        guard canMutateNotes, project.events.contains(where: { $0.id == event.id }) else { return }
        endMemoEditing(); finishEntry()
        var ids = selectedIDs
        if ids.contains(event.id) { ids.remove(event.id) } else { ids.insert(event.id) }
        setSelection(try! TabSelection(ids: ids, primaryID: ids.contains(event.id) ? event.id : nil))
        if let selected { activeString = selected.string; lane = selected.lane }
        requestKeyboardFocus?(); status = "\(ids.count)개 선택 · ⌘클릭 추가/해제 · ⌘드래그 구간 선택"
    }
    func selectAllInLane() {
        guard canMutateNotes else { return }
        endMemoEditing(); finishEntry()
        let ids = Set(project.events.filter { $0.lane == lane }.map(\.id))
        setSelection(try! TabSelection(ids: ids, primaryID: selectedID.flatMap { ids.contains($0) ? $0 : nil }))
        requestKeyboardFocus?()
    }
    @discardableResult
    func selectRange(lane: GuitarLane, from start: Double, to end: Double) -> Bool {
        guard canMutateNotes, start.isFinite, end.isFinite else { return false }
        do {
            let value = try TabSelection.range(in: project, lane: lane, from: min(start, end), to: max(start, end))
            endMemoEditing(); finishEntry(); self.lane = lane
            setSelection(value, range: TimeSpan(start: min(start, end), end: max(start, end)))
            if let selected { activeString = selected.string }
            requestKeyboardFocus?(); status = "\(value.ids.count)개 구간 선택 · 시작 포함 / 끝 제외 · ⌘클릭으로 붙여넣기 위치"
            return true
        } catch { status = "구간 선택 실패 · \(error)"; return false }
    }
    func placeSelectionCursor(_ time: Double) {
        guard canMutateNotes else { return }
        finishEntry(); endMemoEditing(); jumpToScoreTime(time); requestKeyboardFocus?()
        status = "붙여넣기 위치 \(clockLabel(cursor)) · 선택 \(selectedIDs.count)개 유지 · ⌘D 복제"
    }
    @discardableResult
    func applyBatch(_ command: TabEditCommand, requestFocus: Bool = true, preserveInputContext: Bool = false) -> Bool {
        guard canMutateNotes else { return false }
        do {
            let result = try command.apply(to: project)
            guard result.changed else { return false }
            recordUndo(preservingCursor: true); finishEntry()
            project = result.project
            if let pasted = result.pastedSelection { setSelection(pasted) }
            else if case .move = command, !preserveInputContext {
                // After position changes copy starts at the group's current earliest onset.
                setSelection(try! TabSelection(ids: selectedIDs, primaryID: selectedID))
            }
            if !preserveInputContext, let selected { activeString = selected.string; lane = selected.lane }
            changed(); if requestFocus { requestKeyboardFocus?() }; status = "선택 일괄 편집 · ⌘Z 한 번으로 전체 취소"
            return true
        } catch { status = "선택 편집 거절 · 전체 유지 · \(error)"; return false }
    }
    /// A named AX action edits exactly one live UUID, preserving the current group and focus.
    @discardableResult
    func moveAccessibleNote(id: UUID, editorID: UUID, timeDelta: Double = 0, stringDelta: Int = 0) -> Bool {
        guard editorIdentity == editorID, canMutateNotes, timeDelta.isFinite,
              project.events.contains(where: { $0.id == id }) else { return false }
        return applyBatch(.move(selection: try! TabSelection(ids: [id], primaryID: id),
            timeDelta: timeDelta, stringDelta: stringDelta), requestFocus: false, preserveInputContext: true)
    }
    func canAccessNote(id: UUID, editorID: UUID) -> Bool {
        editorIdentity == editorID && canMutateNotes && project.events.contains { $0.id == id }
    }

    @discardableResult
    func offsetSelection(time: Double, strings: Int = 0, targetLane: GuitarLane? = nil) -> Bool {
        applyBatch(.move(selection: editSelection, timeDelta: time, stringDelta: strings, targetLane: targetLane))
    }
    @discardableResult
    func setSelectionLength(_ length: NoteLength?) -> Bool {
        applyBatch(.setLength(selection: editSelection, length: length))
    }
    @discardableResult
    func setSelectionTentative(_ value: Bool) -> Bool {
        applyBatch(.setTentative(selection: editSelection, value: value))
    }
    func selectedFragment() throws -> TabFragment {
        // Preserve leading silence until an edit or explicit UUID toggle changes the range.
        let snapshot = selectionRange == nil ? editSelection : selection
        let copied = try TabFragment.copy(from: project, selection: snapshot)
        let primary = project.events.filter { snapshot.ids.contains($0.id) }.firstIndex { $0.id == selectedID }
        return try TabFragment(events: copied.events, primaryIndex: primary ?? copied.primaryIndex)
    }
    @discardableResult
    func duplicateSelection(targetLane: GuitarLane? = nil) -> Bool {
        guard canMutateNotes, !selectedIDs.isEmpty else { return false }
        do { return applyBatch(.paste(fragment: try selectedFragment(), at: cursor, targetLane: targetLane)) }
        catch { status = "복제 거절 · 전체 유지 · \(error)"; return false }
    }
    @discardableResult
    func copySelection(to pasteboard: NSPasteboard = .general) -> Bool {
        guard canUseTabClipboard, !selectedIDs.isEmpty else { return false }
        do {
            let data = try selectedFragment().encoded()
            pasteboard.clearContents()
            return pasteboard.setData(data, forType: NSPasteboard.PasteboardType(TabFragment.pasteboardType))
        } catch { status = "복사 거절 · \(error)"; return false }
    }
    @discardableResult
    func pasteSelection(from pasteboard: NSPasteboard = .general, targetLane: GuitarLane? = nil) -> Bool {
        guard canUseTabClipboard,
              let data = pasteboard.data(forType: NSPasteboard.PasteboardType(TabFragment.pasteboardType)) else { return false }
        do { return applyBatch(.paste(fragment: try TabFragment.decode(data), at: cursor, targetLane: targetLane)) }
        catch { status = "붙여넣기 거절 · 전체 유지 · \(error)"; return false }
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
        guard let preview = positionDrag, let originals = dragEvents,
              let original = originals.first(where: { $0.id == preview.id }),
              originals.contains(where: { $0.id == event.id }) else { return event }
        var shown = event
        shown.time = event.time + (preview.time - original.time)
        shown.string = event.string + (preview.string - original.string)
        return shown
    }
    func beginPositionDrag(_ event: TabEvent) {
        guard canMutateNotes else { return }
        endMemoEditing()
        guard !busy, let actual = project.events.first(where: { $0.id == event.id }) else { return }
        fretEntry.reset(); newlyCreatedID = nil
        if !selectedIDs.contains(actual.id) { setSelection(try! TabSelection(ids: [actual.id])) }
        selectedID = actual.id; lane = actual.lane; activeString = actual.string
        dragSelection = editSelection
        dragEvents = project.events.filter { selectedIDs.contains($0.id) }
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
        if let originals = dragEvents, originals.count > 1,
           let original = originals.first(where: { $0.id == preview.id }), let dragSelection {
            guard (try? TabEditCommand.move(selection: dragSelection, timeDelta: preview.time - original.time,
                                           stringDelta: preview.string - original.string).apply(to: project)) != nil else {
                status = "선택 전체의 경계를 벗어나 이동할 수 없습니다"; return
            }
        }
        positionDrag = preview
        status = "\(String(format: "%.3f", preview.time))초 · \(preview.string)번 줄 · 놓으면 이동 / Esc 취소"
    }

    func previewMagneticPosition(time: Double, string: Int, screenX: Double, anchors: [NoteMagnetAnchor], shift: Bool) {
        guard canEdit else { return }
        guard time.isFinite, let dragged = positionDrag else { return }
        let candidates = anchors.compactMap { anchor -> NoteMagnetAnchor? in
            guard !selectedIDs.contains(anchor.id),
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
        magnetDragInput = input; positionMagnetTargetID = positionDrag?.time == anchor?.time ? anchor?.id : nil
        if let anchor, positionMagnetTargetID == anchor.id {
            status = "Shift 마그넷 · \(String(format: "%.3f", anchor.time))초에 붙음 · Shift를 놓으면 자유 이동"
        }
    }
    func commitPositionDrag() {
        guard canEdit else { return }
        let preview = positionDrag
        let original = dragEvents?.first { $0.id == preview?.id }
        let batch = dragSelection
        positionDrag = nil; positionMagnetTargetID = nil; magnetDragInput = nil
        dragSelection = nil; dragEvents = nil
        guard let preview, let original, let batch else { return }
        _ = applyBatch(.move(selection: batch, timeDelta: preview.time - original.time,
                            stringDelta: preview.string - original.string))
    }

    func cancelPositionDrag(requestFocus: Bool = true) {
        guard canEdit else { return }
        positionDrag = nil; positionMagnetTargetID = nil; magnetDragInput = nil
        dragSelection = nil; dragEvents = nil
        status = "이동 취소 · 선택 유지 · Esc를 다시 누르면 선택 해제"
        if requestFocus { requestKeyboardFocus?() }
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
        _ = applyBatch(.delete(selection: editSelection))
    }

    func moveSelectedString(by delta: Int) {
        guard canMutateNotes else { return }
        guard let selected else {
            activeString = min(6, max(1, activeString + delta))
            status = "편집 줄 \(activeString)번 · 숫자를 입력하면 현재 위치에 기록"
            return
        }
        if selectedIDs.count > 1 {
            _ = offsetSelection(time: 0, strings: delta); return
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
        if selectedIDs.count > 1 {
            _ = offsetSelection(time: delta); revealSelectedPosition(); return
        }
        guard let time = TimeBounds.clamp(selected.time + delta, duration: project.duration) else { return }
        guard time != selected.time else { return }
        moveSelectedPosition(to: time); revealSelectedPosition()
        status = "위치 \(clockLabel(time)) · Shift+화살표로 정밀 이동"
    }
    func selectAdjacentEvent(backwards: Bool = false) {
        guard canMutateNotes else { return }
        let events = project.events.filter { $0.lane == lane }.sorted {
            if $0.time != $1.time { return $0.time < $1.time }
            if $0.string != $1.string { return $0.string < $1.string }
            return $0.id.uuidString < $1.id.uuidString
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
            finishEntry(); resetSelection() // The next explicit arrow starts another sparse note.
        } else { updateSelected { $0.fret = nil } }
    }
    func toggleTentative() {
        guard let selected else { return }
        _ = setSelectionTentative(!selected.tentative)
    }
    func finishEntry() { guard canMutateNotes else { return }; fretEntry.reset(); newlyCreatedID = nil }
    func clearSelection() {
        guard canEdit else { return }
        if positionDrag != nil { cancelPositionDrag(); return }
        clearPitchDetection()
        finishEntry(); resetSelection(); requestKeyboardFocus?()
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
    private func recordUndo(coalescingMemo: Bool = false, preservingCursor: Bool = false, stemState: StemState? = nil) -> UUID {
        if !coalescingMemo { endMemoEditing() }
        let snapshot = editSnapshot(preservingCursor: preservingCursor, stemState: stemState)
        undoHistory.append(snapshot)
        if undoHistory.count > 100 { undoHistory.removeFirst() }
        redoHistory.removeAll()
        cleanRetiredStemCaches()
        return snapshot.id
    }
    func undoEdit() {
        guard canEdit, exportSnapshot == nil, !exportBusy else { return }
        if positionDrag != nil { cancelPositionDrag(); return }
        endMemoEditing()
        guard let snapshot = undoHistory.last else { return }
        let inverse = editSnapshot(preservingCursor: snapshot.cursor != nil, stemState: snapshot.stemState == nil ? nil : currentStemState())
        guard restore(snapshot) else { return }
        undoHistory.removeLast(); redoHistory.append(inverse)
        cleanRetiredStemCaches()
        status = "입력 취소 · ⇧⌘Z로 다시 실행"
    }
    func redoEdit() {
        guard canMutateNotes else { return }
        endMemoEditing()
        guard let snapshot = redoHistory.last else { return }
        let inverse = editSnapshot(preservingCursor: snapshot.cursor != nil, stemState: snapshot.stemState == nil ? nil : currentStemState())
        guard restore(snapshot) else { return }
        redoHistory.removeLast(); undoHistory.append(inverse)
        cleanRetiredStemCaches()
        status = "입력 다시 실행"
    }
    private func restore(_ snapshot: EditSnapshot) -> Bool {
        if let state = snapshot.stemState {
            let candidate: ScoreProject
            do { candidate = try project.attachingStem(state.asset) }
            catch { self.error = error.localizedDescription; return false }
            if assetRole == .importedGuitarStem, !switchAsset(.original) { return false }
            stopInactivePlayers()
            if let old = stemAudio { retiredStemResources[old.generation] = old.resource }
            retiredStemResources[state.audio.generation] = state.audio.resource
            stemAudio = state.audio; inactivePlayers = state.players
            project = candidate
            for (key, summary) in state.analyses { project.analyses[key] = summary }
            stemConnection = stemDescription(state.audio, asset: state.asset)
        }
        positionDrag = nil; positionMagnetTargetID = nil; magnetDragInput = nil
        dragSelection = nil; dragEvents = nil
        project.events = snapshot.events
        selection = snapshot.selection; selectionRange = snapshot.selectionRange
        selectedID = snapshot.selectedID; activeString = snapshot.activeString
        pruneSelection()
        project.tuning = snapshot.tuning; project.tuningDefinition = snapshot.tuningDefinition
        fretEntry.reset(); newlyCreatedID = nil
        if let selected { lane = selected.lane }
        if let cursor = snapshot.cursor { jumpToScoreTime(cursor) }
        else if let selected { jumpToScoreTime(selected.time) }
        changed(); requestKeyboardFocus?()
        return true
    }
    private func changed() {
        clearPitchDetection()
        projectRevision &+= 1
        refreshSaveState()
        scheduleAutosave()
    }
    private func editSnapshot(preservingCursor: Bool = false, stemState: StemState? = nil) -> EditSnapshot {
        EditSnapshot(events: project.events, selectedID: selectedID, selection: selection, selectionRange: selectionRange,
                     cursor: preservingCursor ? cursor : nil, activeString: activeString,
                     tuning: project.tuning, tuningDefinition: project.tuningDefinition, stemState: stemState)
    }
    private func refreshSaveState() {
        dirty = savedProject.map { project != $0 } ?? true
        saveState = dirty ? (projectURL == nil ? .unsaved : .pending) : (projectURL == nil ? .unsaved : .saved)
    }
    private var currentSession: WorkspaceSession {
        var value = WorkspaceSession()
        value.cursor = playing ? boundedPlaybackTime(livePlayerTime(player)) : cursor
        value.lane = lane.rawValue; value.asset = assetRole.rawValue; value.assetID = activeAsset?.id; value.channel = source.rawValue
        value.windowStart = windowStart; value.windowLength = windowLength; value.rate = rate
        value.scoreView = scoreView; value.measuresPerSystem = measuresPerSystem; value.scorePage = scorePage
        value.showBothLanes = showBothLanes; value.showScoreWaveforms = showScoreWaveforms; value.followScore = followScore
        value.showLengths = showLengths; value.snapToBeat = snapToBeat
        value.loopStart = loopStart; value.loopEnd = loopEnd; value.looping = looping
        return value.bounded(to: project, stemAvailable: stemAudio != nil)
    }

    /// Coalesce direct SwiftUI bindings and transport ticks. Continuous playback writes at most once
    /// per second; resetting a debounce at every tick would never persist a long-running song.
    private func sessionChanged() {
        guard !closed, !busy, !restoringSession, projectURL != nil, sessionTask == nil else { return }
        let identity = projectIdentity
        sessionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, !Task.isCancelled, !self.closed, self.projectIdentity == identity else { return }
            self.sessionTask = nil
            guard !self.busy else { return }
            self.flushSession()
        }
    }

    /// Separate from note autosave/baseline/undo. Failure is advisory even after durable publication.
    func flushSession() {
        sessionTask?.cancel(); sessionTask = nil
        guard !closed, !restoringSession, let url = projectURL else { return }
        // Associate with the durable document, even while an unsaved relink/title edit is pending.
        let document = savedProject ?? project
        let value = currentSession, identity = WorkspaceSessionStore.documentIdentity(document)
        guard value != lastPersistedSession || url != lastSessionURL || identity != lastSessionIdentity else { return }
        if persistSession(value, to: url, project: document) {
            lastPersistedSession = value; lastSessionURL = url; lastSessionIdentity = identity
        }
    }

    @discardableResult
    private func persistSession(_ value: WorkspaceSession, to url: URL, project: ScoreProject) -> Bool {
        do {
            try services.sessionStore.write(value, url, project)
            sessionPersistenceError = nil
            return true
        } catch {
            sessionPersistenceError = "작업 위치 저장 실패 · TAB 저장 상태는 유지됩니다: " + error.localizedDescription
            return false
        }
    }

    func awaitSessionPersistence() async { await sessionTask?.value }

    /// Await the currently scheduled note revision; callers still inspect durable bytes and dirty state.
    func awaitAutosave() async { await autosaveTask?.value }
    func awaitLoading() async { await loadTask?.value }

    private func scheduleAutosave() {
        autosaveTask?.cancel(); autosaveTask = nil
        guard !closed, dirty, let url = projectURL else { return }
        let identity = projectIdentity, revision = projectRevision
        autosaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            guard let self, !Task.isCancelled, !self.closed,
                  self.projectIdentity == identity, self.projectRevision == revision,
                  self.projectURL == url, self.dirty else { return }
            self.autosaveTask = nil
            // A load pauses saving; its completion/cancellation always resumes the retained revision.
            guard self.canSave else { return }
            _ = self.save(to: url)
        }
    }

    @discardableResult
    func analyze() -> Task<Void, Never>? {
        guard canEdit, let prepared, !analyzing else { return nil }
        let target = source, identityID = projectIdentity, duration = project.duration
        let asset = activeAsset, key = project.analysisKey(asset: activeAsset, channel: source)
        let id = UUID()
        analysisID = id
        analyzing = true; status = "\(target.title) 분석 중…"
        analysisTask = Task {
            defer {
                if analysisID == id { analyzing = false; analysisTask = nil; analysisID = nil }
            }
            do {
                let summary: AnalysisSummary
                if let environment = services.cacheEnvironment, let cached = prepared.resource.cached {
                    summary = try await environment.summary(cached, channel: target, modelVersion: services.analyzerVersion,
                        inputMode: services.analysisInputMode, produce: services.analyze)
                } else {
                    let access = try prepared.fileAccess(for: target)
                    defer { withExtendedLifetime(access) {} }
                    summary = try await services.analyze(access.url, duration)
                    try access.validate()
                }
                try Task.checkCancellation()
                guard !closed, analysisID == id, projectIdentity == identityID,
                      self.prepared?.generation == prepared.generation else { return }
                if let identity = prepared.identity {
                    let fingerprint = try await AudioPreparation.fingerprint(prepared.original)
                    try Task.checkCancellation()
                    guard !closed, analysisID == id, projectIdentity == identityID,
                          self.prepared?.generation == prepared.generation,
                          fingerprint == identity.sha256 else { throw AudioIssue.unsupported }
                }
                var attributed = summary
                attributed.provenance = nil
                if let asset, let identity = prepared.identity, asset.identity == identity {
                    attributed.provenance = AnalysisProvenance(assetID: asset.id, identity: identity,
                        channel: target.rawValue, analyzerVersion: services.analyzerVersion,
                        settings: "original-seconds-v1;offset=\(asset.originalTimeOffset)")
                }
                var candidate = project
                candidate.analyses[key] = attributed
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
    /// Advisory clean-mono pitch detection on the selected channel's actual original-time audio.
    /// A bounded region is read; no manual UUID, fingering, rhythm or confidence flag is mutated.
    @discardableResult
    func proposePitches(from start: Double, to end: Double) -> Task<Void, Never>? { propose(.mono, from: start, to: end) }
    /// Basic Pitch chord/polyphonic candidates for the same selected channel and region.
    @discardableResult
    func proposeChords(from start: Double, to end: Double) -> Task<Void, Never>? { propose(.basicPitch, from: start, to: end) }

    private func propose(_ engine: PitchProposal.Source, from start: Double, to end: Double) -> Task<Void, Never>? {
        guard canEdit, !analyzing, source != .stereo, let audio = prepared,
              start.isFinite, end.isFinite, start >= 0, end > start, end <= project.duration, end - start <= 60 else { return nil }
        let channel = source, identity = projectIdentity, id = UUID()
        analysisID = id; analyzing = true; pitchProposals = []
        let environment = services.cacheEnvironment
        let worker = Task.detached(priority: .userInitiated) { () throws -> [PitchProposal] in
            if engine == .mono, let environment, let cached = audio.resource.cached {
                return try await environment.pitches(cached, channel: channel, from: start, to: end).proposals.map(PitchProposal.init)
            }
            let access = try audio.fileAccess(for: channel)
            defer { withExtendedLifetime(access) {} }
            let region = try AudioPreparation.readRegion(access.url, from: start, to: end)
            let proposals = switch engine {
            case .mono: try MonophonicTranscriber().analyze(samples: region.samples, sampleRate: region.sampleRate,
                timeOrigin: region.origin, isCancelled: { Task.isCancelled }).proposals.map(PitchProposal.init)
            case .basicPitch: try BasicPitchTranscriber().transcribe(samples: region.samples, sampleRate: region.sampleRate,
                timeOrigin: region.origin, isCancelled: { Task.isCancelled }).map(PitchProposal.init)
            }
            try access.validate()
            return proposals
        }
        let task = Task {
            defer { if analysisID == id { analyzing = false; analysisID = nil; analysisTask = nil } }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, !closed, analysisID == id, projectIdentity == identity,
                      prepared?.generation == audio.generation, source == channel else { return }
                if let content = audio.identity {
                    guard try await AudioPreparation.fingerprint(audio.original) == content.sha256 else { throw AudioIssue.sourceChanged }
                }
                guard !Task.isCancelled, !closed, analysisID == id, projectIdentity == identity,
                      prepared?.generation == audio.generation, source == channel else { return }
                showProposals(result, lane: channel == .left ? .left : .right)
                status = (engine == .mono ? "실험적 단음 후보 " : "코드·다성 후보 (Basic Pitch) ")
                    + "\(result.count)개 · 수락 전에는 TAB 변경 없음"
            } catch { if !closed, analysisID == id { self.error = error.localizedDescription } }
        }
        analysisTask = task; return task
    }

    func showProposals(_ proposals: [PitchProposal], lane: GuitarLane) {
        pitchProposals = proposals; proposalLane = lane
    }

    /// The note a proposal would become: its MIDI at the best FingeringResolver position whose
    /// string is free (notes in the lane within 30 ms sound together, as a chord), or `?` when the
    /// pitch is unknown, unplayable or has no free string. Rhythm stays nil.
    func proposedNote(_ proposal: PitchProposal) -> TabEvent { proposedNote(proposal, in: project) }
    private func proposedNote(_ proposal: PitchProposal, in project: ScoreProject) -> TabEvent {
        let used = Set(project.events.filter { $0.lane == proposalLane && abs($0.time - proposal.onset) < 0.03 }.map(\.string))
        let best = proposal.midi.flatMap { midi in
            FingeringResolver.resolve(midi: midi, project: project,
                context: FingeringContext(lane: proposalLane, time: proposal.onset)).candidates.first { !used.contains($0.string) }
        }
        let string = best?.string ?? ([activeString] + Array(1...6)).first { !used.contains($0) } ?? activeString
        return TabEvent(time: proposal.onset, lane: proposalLane, string: string, fret: best?.fret, tentative: true)
    }

    /// Inserts tentative notes at the exact onsets in one undo step. A row whose note already
    /// exists (same lane and sounding pitch within 30 ms) is skipped; existing TAB is never changed.
    /// Rows accepted together that sound together get different strings.
    @discardableResult
    func acceptProposals(_ chosen: [PitchProposal]) -> Int {
        guard canMutateNotes, !chosen.isEmpty else { return 0 }
        func pitch(_ event: TabEvent, in project: ScoreProject) -> Int? {
            event.fret.flatMap { project.soundingMIDI(string: event.string, fret: $0) }
        }
        var candidate = project, added: [UUID] = []
        for proposal in chosen {
            guard !candidate.events.contains(where: {
                $0.lane == proposalLane && abs($0.time - proposal.onset) < 0.03 && pitch($0, in: candidate) == proposal.midi
            }) else { continue }
            let note = proposedNote(proposal, in: candidate)
            candidate.events.append(note); added.append(note.id)
        }
        guard (try? candidate.validated()) != nil else { status = "후보 수락 실패 · TAB 유지"; return 0 }
        pitchProposals.removeAll { chosen.contains($0) }
        let skipped = chosen.count - added.count
        guard !added.isEmpty else { status = "같은 음이 이미 있어 건너뜀 · TAB 변경 없음"; return 0 }
        recordUndo(preservingCursor: true); finishEntry()
        project = candidate
        setSelection(try! TabSelection(ids: Set(added), primaryID: added.first))
        changed()
        status = "후보 \(added.count)개 수락 · 잠정 음" + (skipped > 0 ? " · 같은 음 \(skipped)개 건너뜀" : "") + " · ⌘Z 한 번으로 취소"
        return added.count
    }
    @discardableResult
    func acceptQualifiedProposals() -> Int { acceptProposals(pitchProposals.filter(\.qualified)) }
    func rejectProposal(_ proposal: PitchProposal) {
        pitchProposals.removeAll { $0 == proposal }
        status = "후보 거절 · TAB 변경 없음"
    }

    func cancelAnalysis() {
        analysisTask?.cancel(); analysisTask = nil; analysisID = nil; analyzing = false
        if !closed { status = "분석 취소됨" }
    }

    private var retiredStemResources: [UUID: PreparedAudioResource] = [:]
    private func currentStemState() -> StemState? {
        guard let asset = project.stemAsset, let audio = stemAudio else { return nil }
        return StemState(asset: asset, analyses: project.analyses.filter { $0.value.provenance?.assetID == asset.id },
                         audio: audio, players: assetRole == .importedGuitarStem ? preparedPlayers : inactivePlayers)
    }
    private func cleanRetiredStemCaches() {
        let states = (undoHistory + redoHistory).compactMap(\.stemState)
        let retained = Set(states.map { $0.audio.generation }).union(stemAudio.map { [$0.generation] } ?? [])
            .union(outgoingAssetAudio.map { [$0.generation] } ?? [])
        for (id, resource) in retiredStemResources where !retained.contains(id) { resource.disposeScratch() }
        retiredStemResources = retiredStemResources.filter { retained.contains($0.key) }
    }

    private func stemDescription(_ audio: PreparedAudio?, asset: AudioAsset?) -> String {
        guard let asset else { return "스템 없음" }
        guard let audio, let mapping = audio.mapping else { return "스템 오프라인 · 다시 연결" }
        let window = mapping.validOriginalWindow
        return (audio.isMono ? "모노 · L/R 명시적 복제" : "스테레오 · 양쪽 채널 보존") +
            String(format: " · 파일 %.3fs · 오프셋 %+.3fs · 원곡 %.3f–%.3fs · 바깥은 무음", mapping.assetDuration,
                   asset.originalTimeOffset, window.start, window.end)
    }

    private func prepareStem(_ path: String, asset: AudioAsset, duration: Double, requireIdentity: Bool,
                             operation: LoadOperation, package: PortableProjectPackage.Snapshot? = nil) async throws -> (audio: PreparedAudio, asset: AudioAsset) {
        let url = try assetURL(asset, package: package)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let raw = try await services.prepare(url) { [weak self] progress in
            await self?.publishProgress(progress * 0.5, operation: operation)
        }
        defer { raw.resource.disposeScratch() }
        try requireCurrent(operation)
        guard let identity = raw.identity else { throw AudioIssue.unsupported }
        if requireIdentity, identity != asset.identity { throw AudioIssue.sourceChanged }
        if asset.reference.kind == .contained { _ = try package?.resolve(assetID: asset.id) }
        var candidate = asset; candidate.identity = identity
        let aligned = try await services.align(raw, candidate, duration)
        do {
            try requireCurrent(operation)
            guard try await AudioPreparation.fingerprint(url) == identity.sha256 else { throw AudioIssue.sourceChanged }
            if asset.reference.kind == .contained { _ = try package?.resolve(assetID: asset.id) }
            try requireCurrent(operation)
        } catch { aligned.resource.disposeScratch(); throw error }
        return (aligned, candidate)
    }

    private func prepareGroup(_ audio: PreparedAudio) throws -> [ListeningSource: PreparedPlayer] {
        try services.prepareTransport(audio)
        var group: [ListeningSource: PreparedPlayer] = [:]
        do {
            for channel in ListeningSource.allCases {
                let transport = try services.makePlayer(audio, channel)
                let volume = transport.volume
                transport.volume = 0; transport.enableRate = true; transport.rate = rate
                guard transport.prepareToPlay() else { throw AudioIssue.playbackFailed }
                group[channel] = PreparedPlayer(transport: transport, volume: volume)
            }
            return group
        } catch {
            group.values.forEach { $0.transport.stop() }; services.discardPreparedTransport(audio)
            throw error
        }
    }

    func importStem() {
        guard canLoad else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false
        panel.message = "현재 TAB에 기타 스템을 연결합니다. 정렬은 자동 추정하지 않습니다. 모노 파일은 L/R에 명시적으로 복제됩니다."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = attachStem(at: url, offset: project.stemAsset?.originalTimeOffset ?? 0)
    }

    /// Attach/relink/offset prepare a separate muted graph before committing any document state.
    @discardableResult
    func attachStem(at url: URL, offset: Double = 0) -> Task<Bool, Never>? {
        attachStem(at: url, offset: offset, preserving: nil)
    }

    private func attachStem(at url: URL, offset: Double, preserving existing: AudioAsset?) -> Task<Bool, Never>? {
        guard canLoad, project.originalAsset != nil, offset.isFinite, abs(offset) <= 86_400,
              let operation = reserveLoad() else { return nil }
        var asset = existing ?? AudioAsset(id: project.stemAsset?.id ?? UUID(), role: .importedGuitarStem,
            reference: AudioReference(path: url.path), originalTimeOffset: offset)
        asset.originalTimeOffset = offset
        let inputAsset = asset
        let package = currentPackage
        let task = Task { () -> Bool in
            var audio: PreparedAudio?, group: [ListeningSource: PreparedPlayer] = [:], committed = false
            defer {
                if !committed {
                    group.values.forEach { $0.transport.stop() }
                    if let audio { services.discardPreparedTransport(audio); audio.resource.disposeScratch() }
                }
                if loadOperation?.id == operation.id {
                    loadOperation = nil; loadTask = nil; busy = false; scheduleAutosave(); sessionChanged()
                }
            }
            do {
                let staged = try await prepareStem(url.path, asset: inputAsset, duration: project.duration,
                    requireIdentity: existing != nil, operation: operation, package: package)
                audio = staged.audio
                let candidate = try operation.snapshot.attachingStem(staged.asset)
                group = try prepareGroup(staged.audio)
                guard try await AudioPreparation.fingerprint(url) == staged.asset.identity?.sha256 else { throw AudioIssue.sourceChanged }
                try requireCurrent(operation)
                // Keep the usable original playing at its current live clock. Replacing an auditioned
                // stem first hands back to the prepared original; no old graph survives cache deletion.
                if assetRole == .importedGuitarStem {
                    busy = false
                    guard switchAsset(.original) else { busy = true; throw AudioIssue.playbackFailed }
                    busy = true
                }
                let offsetEdit = project.stemAsset.map {
                    $0.identity == staged.asset.identity && $0.reference == staged.asset.reference &&
                    $0.originalTimeOffset != staged.asset.originalTimeOffset
                } ?? false
                try requireCurrent(operation)
                let previousState = currentStemState()
                // Bound offset undo to one retired streaming cache. Ordinary note history stays intact.
                undoHistory.removeAll { $0.stemState != nil }; redoHistory.removeAll { $0.stemState != nil }
                cleanRetiredStemCaches()
                if offsetEdit, let previousState {
                    retiredStemResources[previousState.audio.generation] = previousState.audio.resource
                    recordUndo(preservingCursor: true, stemState: previousState)
                }
                stopInactivePlayers()
                if !offsetEdit, let old = stemAudio { retiredStemResources[old.generation] = old.resource }
                stemAudio = staged.audio; inactivePlayers = group; project = candidate
                cleanRetiredStemCaches()
                stemConnection = stemDescription(staged.audio, asset: staged.asset)
                committed = true; changed(); status = "스템 연결 완료 · 수동 TAB 유지 · 오프셋은 원곡 초 기준"
                return true
            } catch {
                if !closed, loadOperation?.id == operation.id {
                    self.error = error.localizedDescription; status = "스템 준비 실패 · 이전 원곡/TAB/스템 유지"
                }
                return false
            }
        }
        loadTask = task; return task
    }

    @discardableResult
    func setStemOffset(_ offset: Double) -> Task<Bool, Never>? {
        guard let asset = project.stemAsset else { return nil }
        do { return attachStem(at: try assetURL(asset, package: currentPackage), offset: offset, preserving: asset) }
        catch { self.error = error.localizedDescription; return nil }
    }

    /// Separate asset graphs share the production streaming Engine implementation. Each handover
    /// captures the OLD live original clock after destination preparation and rolls back on failure.
    @discardableResult
    func switchAsset(_ role: AudioAsset.Role) -> Bool {
        guard canMutateNotes else { return false }
        if role == assetRole { return true }
        if let pending = scheduledStart, let audible = outgoingAssetPlayers[outgoingSource ?? source]?.transport {
            if audible.deviceCurrentTime >= pending.epoch { finishAssetHandover() }
            else if role == outgoingAssetRole {
                let currentAudio = role == .original ? originalAudio : stemAudio
                guard let outgoing = outgoingAssetAudio, outgoing.generation == currentAudio?.generation,
                      outgoingAssetPlayers[source]?.transport.isPlaying == true else {
                    error = AudioIssue.playbackFailed.localizedDescription; return false
                }
                // Reversing a queued transition uses the still-rendering graph, with no seek or
                // new epoch. Validate through each transport boundary before cancelling anything.
                for cached in outgoingAssetPlayers.values {
                    guard cached.transport.prepareToPlay(), cached.transport.isPlaying,
                          cached.scheduledEpoch.map({ cached.transport.play(atTime: $0) }) ?? true else {
                        error = AudioIssue.playbackFailed.localizedDescription; return false
                    }
                }
                let layout = scoreLayout
                cancelAssetHandoverReturningToOutgoing(); reflowScore(from: layout)
                return true
            }
        }
        if role == .original, originalAudio == nil {
            let sampled = boundedPlaybackTime(livePlayerTime(player))
            pausePlayers(); preparedPlayers.values.forEach { $0.transport.volume = 0 }
            inactivePlayers = preparedPlayers; preparedPlayers = [:]; player = nil; prepared = nil
            assetRole = .original; cursor = sampled; playing = false; scheduledStart = nil; pitchProposals = []
            return true
        }
        guard let audio = role == .original ? originalAudio : stemAudio else {
            error = "연결된 오디오를 사용할 수 없습니다 · 다시 연결하세요"; return false
        }
        let layout = scoreLayout, old = player
        let identity = projectIdentity, oldGeneration = prepared?.generation, previousRole = assetRole, channel = source
        func requireHandover() throws {
            guard canMutateNotes, projectIdentity == identity, prepared?.generation == oldGeneration,
                  self.player === old, assetRole == previousRole, source == channel else { throw CancellationError() }
        }
        var group = inactivePlayers
        do {
            for channel in ListeningSource.allCases where group[channel] == nil {
                let t = try services.makePlayer(audio, channel); let volume = t.volume
                t.volume = 0; t.rate = rate; t.enableRate = true
                guard t.prepareToPlay() else { throw AudioIssue.playbackFailed }
                group[channel] = PreparedPlayer(transport: t, volume: volume)
            }
            try requireHandover()
            guard let destination = group[channel]?.transport else { throw AudioIssue.playbackFailed }
            let sampled = livePlayerTime(old)
            let loopWrap = looping && sampled >= loopEnd
            let resume = playing && ((old?.isPlaying == true && sampled < project.duration) || loopWrap)
            let clock = old?.clockSnapshot()
            let pending = scheduledStart
            let reference = loopWrap ? nil : (pending.map { PlaybackClockSnapshot(position: $0.position, deviceTime: $0.epoch) } ?? clock)
            let start = try scheduleAssetGroup(group, destination: destination, reference: reference,
                                               stationary: pending != nil, parked: loopWrap ? loopStart : boundedPlaybackTime(sampled), resume: resume)
            let time = start.position, epoch = start.epoch
            try requireHandover()
            if resume {
                outgoingAssetPlayers = preparedPlayers
                outgoingAssetAudio = prepared; outgoingAssetRole = assetRole; outgoingSource = source; outgoingScheduledStart = scheduledStart
                armAssetHandover(epoch: epoch, destination: destination)
            } else { pausePlayers(); preparedPlayers.values.forEach { $0.transport.volume = 0 } }
            inactivePlayers = preparedPlayers; preparedPlayers = group
            prepared = audio; assetRole = role; player = destination; pitchProposals = []
            destination.volume = group[source]!.volume
            playing = resume
            scheduledStart = resume ? ScheduledStart(epoch: epoch, position: time) : nil
            if resume { for (key, var cached) in preparedPlayers { cached.scheduledEpoch = epoch; preparedPlayers[key] = cached } }
            cursor = resume ? boundedPlaybackTime(livePlayerTime(destination)) : time
            reflowScore(from: layout)
            return true
        } catch {
            group.values.forEach { $0.transport.pause(); $0.transport.volume = 0 }
            if !closed, projectIdentity == identity { self.error = error.localizedDescription }
            return false
        }
    }

    func detachStem() {
        if busy { cancelLoading() }
        guard canLoad, project.stemAsset != nil else { return }
        if assetRole == .importedGuitarStem, !switchAsset(.original) { return }
        stopInactivePlayers()
        inactivePlayers.removeAll()
        if let stemAudio { retiredStemResources[stemAudio.generation] = stemAudio.resource }
        stemAudio = nil; stemConnection = "스템 없음"
        undoHistory.removeAll { $0.stemState != nil }; redoHistory.removeAll { $0.stemState != nil }; cleanRetiredStemCaches()
        if let candidate = try? project.detachingStem() { project = candidate; changed() }
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

    private func reserveLoad(requestFocus: Bool = true, authorizesReservation: () -> Bool = { true }) -> LoadOperation? {
        guard !closed, !analyzing, saveOperation == nil, loadOperation == nil, !busy || startupPending else { return nil }
        cancelPositionDrag(requestFocus: requestFocus); endMemoEditing()
        clearPitchDetection()
        flushSession()
        let session = currentSession
        // Session persistence and focus callbacks may reenter while no load owns the slot.
        // Fence the exact native authorization and live export eligibility after every callback,
        // before capturing a newer model or marking busy. Startup is never an export exception.
        guard authorizesReservation(), !closed, !analyzing, saveOperation == nil, loadOperation == nil,
              !busy || startupPending, exportSnapshot == nil, !exportBusy else { return nil }
        let operation = LoadOperation(projectID: projectIdentity, snapshot: project, session: session)
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
        if externalProjectOperationID == loadOperation?.id {
            externalProjectOperationID = nil
            externalOpenDidCancelLoad?()
        }
        automaticStartupOperationID = nil
        loadTask?.cancel(); loadTask = nil; loadOperation = nil
        busy = false; loadProgress = 0
        if !closed { status = "오디오 준비 취소됨 · 이전 작업 유지"; scheduleAutosave(); sessionChanged() }
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

    private func assetURL(_ asset: AudioAsset, package: PortableProjectPackage.Snapshot?) throws -> URL {
        if asset.reference.kind == .external { return URL(fileURLWithPath: asset.reference.path) }
        guard let package else { throw PortableProjectPackage.PackageError.mediaUnavailable }
        return try package.resolve(assetID: asset.id)
    }

    private func stageAudio(_ url: URL, preserving: ScoreProject?, operation: LoadOperation,
                            package: PortableProjectPackage.Snapshot? = nil) async throws -> StagedWorkspace {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let audio = try await services.prepare(url) { [weak self] progress in
            await self?.publishProgress(progress, operation: operation)
        }
        var retained = false
        defer { if !retained { audio.resource.disposeScratch() } }
        try requireCurrent(operation)
        if let preserving, preserving.events.contains(where: { $0.time >= audio.duration }) { throw ProjectError.invalidData }
        let base = preserving ?? ScoreProject(title: url.deletingPathExtension().lastPathComponent, duration: audio.duration)
        var candidate = try base.relinkingOriginal(path: url.path, identity: audio.identity, duration: audio.duration)
        if let package, let asset = base.originalAsset, asset.reference.kind == .contained {
            guard audio.identity == asset.identity else { throw AudioIssue.sourceChanged }
            _ = try package.resolve(assetID: asset.id)
            candidate.assets?[0].reference = asset.reference
            candidate.audioPath = nil
        }
        retained = true
        return StagedWorkspace(project: candidate, audio: audio,
            projectURL: preserving == nil ? nil : projectURL, package: package ?? (preserving == nil ? nil : currentPackage),
            baseline: preserving == nil ? nil : savedProject,
            status: audio.isMono ? "모노 파일 · L/R에는 같은 소리가 들어 있습니다" : "스테레오 준비 완료 · 채널별로 듣고 필요한 음을 남기세요")
    }

    private func stageProject(_ url: URL, operation: LoadOperation) async throws -> StagedWorkspace {
        let package = url.pathExtension.lowercased() == PortableProjectPackage.fileExtension ? try await services.readPackage(url) : nil
        let loaded: ScoreProject
        if let package { loaded = package.project }
        else {
            loaded = try await services.readProject(url).validated()
            guard loaded.assets?.contains(where: { $0.reference.kind == .contained }) != true else {
                throw PortableProjectPackage.PackageError.mediaUnavailable
            }
        }
        try requireCurrent(operation)
        let originalURL = try loaded.originalAsset.map { try assetURL($0, package: package) }
            ?? loaded.audioPath.map { URL(fileURLWithPath: $0) }
        var staged: StagedWorkspace
        if let originalURL, services.fileExists(originalURL) {
            do {
                staged = try await stageAudio(originalURL, preserving: loaded, operation: operation, package: package)
            } catch {
                try requireCurrent(operation)
                let fingerprint = try? await AudioPreparation.fingerprint(originalURL)
                try requireCurrent(operation)
                staged = StagedWorkspace(project: loaded.invalidatingUnverifiedAnalysis(fingerprint: fingerprint), status: "오디오를 열지 못했습니다 · TAB은 오프라인으로 편집할 수 있습니다",
                    offlineReason: error.localizedDescription)
            }
        } else {
            staged = StagedWorkspace(project: loaded.invalidatingUnverifiedAnalysis(fingerprint: nil),
                status: originalURL == nil ? "오디오 없는 TAB 프로젝트 · 편집 가능" : "오디오 경로를 찾을 수 없습니다 · TAB은 오프라인으로 편집할 수 있습니다",
                offlineReason: originalURL == nil ? nil : "연결된 오디오를 찾을 수 없습니다")
        }
        var retained = false
        defer {
            if !retained {
                for audio in [staged.audio, staged.stemAudio].compactMap({ $0 }) {
                    audio.resource.disposeScratch()
                }
            }
        }
        if let asset = loaded.stemAsset {
            do {
                staged.stemAudio = try await prepareStem(asset.reference.path, asset: asset, duration: staged.project.duration,
                    requireIdentity: true, operation: operation, package: package).audio
            } catch {
                try requireCurrent(operation)
                staged.stemReason = "스템 연결 실패 · 원곡/TAB 유지 · 다시 연결: " + error.localizedDescription
                staged.project = try await invalidatingContradictedStem(in: staged.project, asset: asset, operation: operation)
                try requireCurrent(operation)
            }
        }
        staged.projectURL = url; staged.package = package; staged.fromDisk = true; staged.baseline = loaded
        // A cancellation-ignoring lookup must not publish into a subsequently opened document.
        staged.session = try? await services.sessionStore.read(url, loaded)
        try requireCurrent(operation)
        retained = true
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

    /// Missing/unreadable media cannot disprove prior provenance. Readable changed bytes can.
    private func invalidatingContradictedStem(in project: ScoreProject, asset: AudioAsset,
                                             operation: LoadOperation) async throws -> ScoreProject {
        let fingerprint: String?
        if let url = try? assetURL(asset, package: currentPackage) { fingerprint = try? await AudioPreparation.fingerprint(url) }
        else { fingerprint = nil }
        try requireCurrent(operation)
        guard let fingerprint, fingerprint != asset.identity?.sha256 else { return project }
        var candidate = project
        candidate.analyses = candidate.analyses.filter { $0.value.provenance?.assetID != asset.id }
        if let index = candidate.assets?.firstIndex(where: { $0.id == asset.id }) {
            candidate.assets?[index].identity = nil
        }
        return candidate
    }

    private func performLoad(_ request: LoadRequest, operation: LoadOperation) async -> Bool {
        var staged: StagedWorkspace?
        var committed = false
        defer {
            if !committed {
                if let audio = staged?.audio {
                    services.discardPreparedTransport(audio)
                    audio.resource.disposeScratch()
                }
                if let audio = staged?.stemAudio {
                    services.discardPreparedTransport(audio); audio.resource.disposeScratch()
                }
                if let url = staged?.demoURL { try? FileManager.default.removeItem(at: url) }
            }
            if loadOperation?.id == operation.id {
                if automaticStartupOperationID == operation.id { automaticStartupOperationID = nil }
                if externalProjectOperationID == operation.id { externalProjectOperationID = nil }
                loadTask = nil; loadOperation = nil; busy = false
                if !closed { scheduleAutosave(); sessionChanged() }
            }
        }
        do {
            try requireCurrent(operation)
            switch request {
            case .startup:
                if let url = services.initialProject() ?? services.lastProject(), services.fileExists(url) {
                    do { staged = try await stageProject(url, operation: operation) }
                    catch {
                        try requireCurrent(operation)
                        staged = try await stageDemo(false, operation: operation)
                    }
                } else { staged = try await stageDemo(false, operation: operation) }
            case .demo(let long): staged = try await stageDemo(long, operation: operation)
            case .audio(let url, let relink):
                staged = try await stageAudio(url, preserving: relink ? operation.snapshot : nil, operation: operation)
                if relink { staged?.session = operation.session }
                if relink, let asset = operation.snapshot.stemAsset {
                    do {
                        let stemDuration = staged?.project.duration ?? project.duration
                        let readyStem = try await prepareStem(asset.reference.path, asset: asset,
                            duration: stemDuration, requireIdentity: true, operation: operation, package: currentPackage).audio
                        staged?.stemAudio = readyStem
                    } catch {
                        try requireCurrent(operation)
                        staged?.stemReason = "스템 오프라인 · 다시 연결: " + error.localizedDescription
                        if let project = staged?.project {
                            staged?.project = try await invalidatingContradictedStem(in: project, asset: asset, operation: operation)
                        }
                    }
                }
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
                if let audio = candidate.audio {
                    services.discardPreparedTransport(audio)
                    audio.resource.disposeScratch()
                }
                candidate.project = decoded.invalidatingUnverifiedAnalysis(fingerprint: fingerprint)
                candidate.audio = nil
                candidate.offlineReason = error.localizedDescription
                candidate.status = "오디오를 열지 못했습니다 · TAB은 오프라인으로 편집할 수 있습니다"
                staged = candidate; stagedPlayer = nil
            }
            // Player initialization can fail or reenter through an injected service.
            // Recheck ownership only after all fallible work and before touching old state.
            try requireCurrent(operation)
            var stemPlayers: [ListeningSource: PreparedPlayer] = [:]
            if let stem = candidate.stemAudio {
                do {
                    stemPlayers = try prepareGroup(stem)
                    guard try await AudioPreparation.fingerprint(stem.original) == stem.identity?.sha256 else { throw AudioIssue.sourceChanged }
                }
                catch {
                    stemPlayers.values.forEach { $0.transport.stop() }; stemPlayers.removeAll()
                    services.discardPreparedTransport(stem)
                    stem.resource.disposeScratch()
                    candidate.stemAudio = nil; candidate.stemReason = "스템 재생 준비 실패 · 다시 연결: " + error.localizedDescription
                }
            }
            var session = (candidate.session ?? WorkspaceSession()).bounded(to: candidate.project, stemAvailable: candidate.stemAudio != nil)
            if candidate.isDemo { session.cursor = 2; session.loopStart = 2; session.loopEnd = min(6, candidate.project.duration) }
            var selectedPlayer = stagedPlayer
            let restoringStem = session.asset == "importedGuitarStem"
            var originalChannel = restoringStem ? ListeningSource.stereo : (ListeningSource(rawValue: session.channel) ?? .stereo)
            if !restoringStem, let audio = candidate.audio,
               let channel = ListeningSource(rawValue: session.channel), channel != .stereo {
                do {
                    let transport = try services.makePlayer(audio, channel)
                    transport.enableRate = true; transport.rate = session.rate
                    guard transport.prepareToPlay() else { throw AudioIssue.playbackFailed }
                    selectedPlayer = transport
                } catch { session.channel = "stereo"; originalChannel = .stereo }
            }
            // Channel preparation can fall back too; page bounds/follow use the channel actually parked.
            session = session.bounded(to: candidate.project, stemAvailable: candidate.stemAudio != nil)
            try candidate.package?.validate()
            try requireCurrent(operation)
            flushSession()
            try requireCurrent(operation)
            restoringSession = true
            activate(candidate, player: selectedPlayer, originalChannel: originalChannel, session: session)
            stemAudio = candidate.stemAudio; inactivePlayers = stemPlayers
            if session.asset == "importedGuitarStem", let stem = stemAudio,
               let channel = ListeningSource(rawValue: session.channel), let destination = stemPlayers[channel] {
                inactivePlayers = preparedPlayers; preparedPlayers = stemPlayers
                prepared = stem; assetRole = .importedGuitarStem; player = destination.transport; source = channel
            }
            // Park every prepared transport, including inactive asset graphs. Never resume playback.
            for (channel, cached) in preparedPlayers {
                cached.transport.pause(); cached.transport.rate = rate; cached.transport.currentTime = cursor
                cached.transport.volume = channel == source ? cached.volume : 0
            }
            for cached in inactivePlayers.values {
                cached.transport.pause(); cached.transport.rate = rate; cached.transport.currentTime = cursor; cached.transport.volume = 0
            }
            stemConnection = candidate.stemReason ?? stemDescription(candidate.stemAudio, asset: candidate.project.stemAsset)
            restoringSession = false
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
        try services.prepareTransport(audio)
        let candidate = try services.makePlayer(audio, .stereo)
        candidate.enableRate = true; candidate.rate = rate
        candidate.currentTime = staged.isDemo ? 2 : 0
        guard candidate.prepareToPlay() else { throw AudioIssue.unsupported }
        return candidate
    }

    private func activate(_ staged: StagedWorkspace, player stagedPlayer: (any AudioPlayerTransport)?,
                          originalChannel: ListeningSource, session: WorkspaceSession) {
        stopAndCleanAudio()
        let previousDemo = demoURL
        if let previousDemo, previousDemo != staged.audio?.original {
            try? FileManager.default.removeItem(at: previousDemo)
        }
        demoURL = staged.demoURL ?? (previousDemo == staged.audio?.original ? previousDemo : nil)
        pitchProposals = []
        prepared = staged.audio; originalAudio = staged.audio; assetRole = .original; project = staged.project
        audioConnection = staged.offlineReason.map { "오프라인 · " + $0 } ??
            (staged.audio?.isMono == true ? "모노 연결됨 · L/R 동일" : "스테레오 연결됨 · 원본 L/R")
        projectIdentity = UUID(); projectURL = staged.projectURL; currentPackage = staged.package; isDemo = staged.isDemo
        resetSelection(); activeString = 6
        cursor = session.cursor; windowStart = session.windowStart; windowLength = session.windowLength
        lane = GuitarLane(rawValue: session.lane) ?? .left
        rate = session.rate; scoreView = session.scoreView; measuresPerSystem = session.measuresPerSystem
        showBothLanes = session.showBothLanes; showScoreWaveforms = session.showScoreWaveforms
        showLengths = session.showLengths; snapToBeat = session.snapToBeat
        lastPersistedSession = nil; lastSessionURL = nil; sessionPersistenceError = nil
        positionDrag = nil; positionMagnetTargetID = nil; magnetDragInput = nil
        dragSelection = nil; dragEvents = nil
        memoSession = nil
        undoHistory.removeAll(); redoHistory.removeAll(); fretEntry.reset(); newlyCreatedID = nil
        inspectorVisible = false; scorePage = session.scorePage; followScore = session.followScore
        loopStart = session.loopStart; loopEnd = session.loopEnd
        looping = session.looping; source = originalChannel
        player = stagedPlayer
        if let stagedPlayer { preparedPlayers[source] = PreparedPlayer(transport: stagedPlayer, volume: stagedPlayer.volume) }
        projectRevision &+= 1
        savedProject = staged.baseline
        refreshSaveState()
        if staged.fromDisk, let url = projectURL { services.rememberProject(url) }
        status = staged.status; requestKeyboardFocus?()
    }

    func save() {
        guard canSave else { return }
        if let projectURL {
            if save(to: projectURL) { status = "프로젝트 저장 완료 · 이후 입력은 자동 저장" }
        } else { chooseSave(action: .save, format: .linked) }
    }

    func saveAs(format: ProjectSaveRequest.Format = .linked) { chooseSave(action: .saveAs, format: format) }
    func saveCopy(format: ProjectSaveRequest.Format = .linked) { chooseSave(action: .saveCopy, format: format) }

    private func chooseSave(action: ProjectSaveRequest.Action, format: ProjectSaveRequest.Format) {
        guard canSave else { return }
        let identity = projectIdentity, revision = projectRevision, snapshot = project, token = UUID()
        saveOperation = token
        let destination = services.chooseSaveDestination(ProjectSaveRequest(title: project.title, action: action, format: format))
        guard saveOperation == token else { return }
        saveOperation = nil
        defer { if !closed, dirty, autosaveTask == nil { scheduleAutosave() } }
        guard !closed, projectIdentity == identity, projectRevision == revision, project == snapshot else { return }
        guard let destination else {
            if action != .saveCopy, dirty { saveState = .cancelled }
            return
        }
        _ = writeSave(to: destination, format: format, copy: action == .saveCopy, replaceActive: false)
    }

    /// Ordinary save/autosave retain their active-destination semantics. A different URL is Save As.
    @discardableResult
    func save(to destination: URL) -> Bool {
        let format: ProjectSaveRequest.Format = destination.pathExtension.lowercased() == PortableProjectPackage.fileExtension ? .collected : .linked
        return writeSave(to: destination, format: format, copy: false, replaceActive: destination.standardizedFileURL == projectURL?.standardizedFileURL)
    }
    @discardableResult
    func saveAs(to destination: URL, format: ProjectSaveRequest.Format = .linked) -> Bool {
        writeSave(to: destination, format: format, copy: false, replaceActive: false)
    }
    @discardableResult
    func saveCopy(to destination: URL, format: ProjectSaveRequest.Format = .linked) -> Bool {
        writeSave(to: destination, format: format, copy: true, replaceActive: false)
    }

    private func writeSave(to destination: URL, format: ProjectSaveRequest.Format, copy: Bool, replaceActive: Bool) -> Bool {
        guard canSave else { return false }
        let token = UUID(), identity = projectIdentity, revision = projectRevision, snapshot = project
        let authorization = externalAuthorization
        saveOperation = token
        if !copy { autosaveTask?.cancel(); autosaveTask = nil; saveState = .saving }
        defer {
            if saveOperation == token {
                saveOperation = nil
                if !closed, dirty, autosaveTask == nil { scheduleAutosave() }
            }
        }
        var copiedAudio: URL?
        let requireSave = {
            guard !self.closed, self.saveOperation == token, self.projectIdentity == identity,
                  self.projectRevision == revision, self.modelGeneration == authorization.generation,
                  self.project == snapshot else { throw CancellationError() }
        }
        do {
            guard destination.pathExtension.lowercased() == format.fileExtension else { throw CocoaError(.fileWriteInvalidFileName) }
            if let currentPackage, !(replaceActive && format == .collected) {
                try PortableProjectPackage.validateDestination(destination, outside: currentPackage.root)
            }
            var saved = try snapshot.validated()
            let package: PortableProjectPackage.Snapshot?
            if format == .collected {
                if replaceActive {
                    guard let currentPackage else { throw PortableProjectPackage.PackageError.invalidDestination }
                    package = try services.updatePackage(saved, currentPackage, requireSave)
                } else {
                    package = try services.collectPackage(saved, destination, currentPackage?.root, requireSave)
                }
                saved = package!.project
            } else {
                package = nil
                // A linked export is explicit external URLs, never orphaned relative references.
                for index in (saved.assets ?? []).indices {
                    if let asset = saved.assets?[index], asset.reference.kind == .contained {
                        let url = try assetURL(asset, package: currentPackage)
                        saved.assets?[index].reference = AudioReference(path: url.path)
                        if asset.role == .original { saved.audioPath = url.path }
                    }
                }
                if !replaceActive, services.fileExists(destination) { throw CocoaError(.fileWriteFileExists) }
                if isDemo, let audio = originalAudio, saved.audioPath == demoURL?.path {
                    let resource = destination.deletingLastPathComponent().appendingPathComponent("RoughScore-demo-" + UUID().uuidString + ".wav")
                    try FileManager.default.copyItem(at: audio.original, to: resource)
                    copiedAudio = resource
                    if let identity = audio.identity {
                        // Verify both ends before publishing any reference to the copied demo.
                        guard try Data(contentsOf: resource) == Data(contentsOf: audio.original),
                              saved.originalAsset?.identity == identity else { throw AudioIssue.sourceChanged }
                    }
                    saved.audioPath = resource.path
                    if let index = saved.assets?.firstIndex(where: { $0.role == .original }) {
                        saved.assets?[index].reference = AudioReference(path: resource.path)
                    }
                }
                _ = try saved.validated()
                try requireSave()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let bytes = try encoder.encode(saved)
                if replaceActive, let savedProject {
                    try LinkedProjectWriter.replace(bytes, at: destination, expected: savedProject,
                        write: services.writeProject, cancellation: requireSave)
                }
                else { try LinkedProjectWriter.create(bytes, at: destination, write: services.writeProject, cancellation: requireSave) }
            }
            // Injected synchronous writers may reenter. They cannot advance the old session.
            try requireSave()
            if copy {
                persistSession(currentSession, to: destination, project: saved)
                status = "프로젝트 사본 저장 완료 · 현재 저장 위치 유지"
                return true
            }
            flushSession()
            try requireSave()
            // Save As rebases active document/media locations without changing editorIdentity.
            // A request captured against the previous storage binding no longer owns an export.
            if !replaceActive { cancelExport() }
            project = saved; savedProject = saved; projectURL = destination; currentPackage = package
            rebasePreparedSources(to: saved, package: package)
            refreshSaveState()
            lastSaveReceipt = .init(before: authorization, after: externalAuthorization)
            services.rememberProject(destination)
            status = "프로젝트 저장 완료 · 이후 입력은 자동 저장"
            flushSession()
            return true
        } catch {
            if let copiedAudio { try? FileManager.default.removeItem(at: copiedAudio) }
            guard !closed, projectIdentity == identity, saveOperation == token else { return false }
            if !copy {
                dirty = savedProject.map { project != $0 } ?? true
                saveState = error is CancellationError ? .cancelled : .failed
            }
            self.error = error.localizedDescription
            // Retained edits still target the old document after a failed/cancelled Save As.
            if !copy, dirty { scheduleAutosave() }
            return false
        }
    }

    /// Change only source locations; cached/scratch leases, graph generations and note history stay owned.
    private func rebasePreparedSources(to saved: ScoreProject, package: PortableProjectPackage.Snapshot?) {
        func rebased(_ audio: PreparedAudio?, asset: AudioAsset?) -> PreparedAudio? {
            guard var audio, let asset, audio.identity == asset.identity else { return audio }
            let url: URL
            if asset.reference.kind == .contained, let package { url = package.root.appendingPathComponent(asset.reference.path) }
            else { url = URL(fileURLWithPath: asset.reference.path) }
            audio.original = url
            return audio
        }
        originalAudio = rebased(originalAudio, asset: saved.originalAsset)
        stemAudio = rebased(stemAudio, asset: saved.stemAsset)
        prepared = assetRole == .original ? originalAudio : stemAudio
        outgoingAssetAudio = rebased(outgoingAssetAudio, asset: outgoingAssetRole == .original ? saved.originalAsset : saved.stemAsset)
        func rebaseHistory(_ history: inout [EditSnapshot]) {
            for index in history.indices {
                guard var state = history[index].stemState, let asset = saved.stemAsset, state.asset.identity == asset.identity else { continue }
                var historyAsset = state.asset; historyAsset.reference = asset.reference
                state = StemState(asset: historyAsset, analyses: state.analyses,
                    audio: rebased(state.audio, asset: asset)!, players: state.players)
                history[index].stemState = state
            }
        }
        rebaseHistory(&undoHistory); rebaseHistory(&redoHistory)
    }

    func openProject() {
        guard canLoad, confirmDiscard(), let operation = reserveLoad() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ProjectSaveRequest.Format.linked.contentType, ProjectSaveRequest.Format.collected.contentType]
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "링크 프로젝트(.roughscore) 또는 오디오 포함 프로젝트(.roughscorepkg)를 엽니다."
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
        beginExport(.tab)
    }

    func exportedText() throws -> String {
        try SparseTabExporter.tab(project, analysis: .init(project: project, asset: activeAsset))
    }

    func beginExport(_ format: ScoreExportFormat) {
        guard canExport else { return }
        let protection = exportDestinationProtection()
        let waveform = prepared.map { ScoreRenderPlan.WaveformInput(duration: $0.duration, left: $0.leftPeaks,
            right: $0.rightPeaks, label: assetRole == .original ? "Original" : "Imported Stem") }
        exportSnapshot = ScoreExportSnapshot(projectID: projectIdentity, initialFormat: format, project: project,
            selectedRange: selectionRange, analysis: .init(project: project, asset: activeAsset), waveform: waveform,
            protectedFiles: protection.files, packageRoot: protection.root)
    }

    private func exportDestinationProtection() -> (files: [URL], root: URL?) {
        var files = [projectURL].compactMap { $0 }
        if let currentPackage { files.append(currentPackage.root.appendingPathComponent("project.json")) }
        if let path = project.audioPath { files.append(URL(fileURLWithPath: path)) }
        for asset in project.assets ?? [] {
            if asset.reference.kind == .external { files.append(URL(fileURLWithPath: asset.reference.path)) }
            else if let currentPackage { files.append(currentPackage.root.appendingPathComponent(asset.reference.path)) }
        }
        return (files, currentPackage?.root)
    }
    func cancelExport() { exportSnapshot = nil }

    @discardableResult
    func completeExport(_ snapshot: ScoreExportSnapshot, options: ScoreExportOptions, to destination: URL? = nil) async -> Bool {
        guard canEdit, !exportBusy, exportSnapshot?.id == snapshot.id, projectIdentity == snapshot.projectID else { return false }
        exportBusy = true
        defer { exportBusy = false; if exportSnapshot?.id == snapshot.id { exportSnapshot = nil } }
        do {
            let producer = Task.detached(priority: .userInitiated) { try snapshot.bytes(options) }
            let data = try await withTaskCancellationHandler { try await producer.value } onCancel: { producer.cancel() }
            try Task.checkCancellation()
            guard !closed, projectIdentity == snapshot.projectID, exportSnapshot?.id == snapshot.id else { return false }
            if options.format == .print {
                let completed = try services.exportServices.print(data, options.settings)
                if completed, projectIdentity == snapshot.projectID { status = "인쇄 문서 작업 완료" }
                return completed
            }
            guard let url = destination ?? services.exportServices.chooseDestination(options.format, snapshot.project.title) else { return false }
            try Task.checkCancellation()
            guard !closed, projectIdentity == snapshot.projectID, exportSnapshot?.id == snapshot.id else { return false }
            let protection = exportDestinationProtection()
            try snapshot.validateDestination(url, format: options.format,
                additionalProtectedFiles: protection.files, additionalPackageRoot: protection.root)
            try Task.checkCancellation()
            try services.exportServices.write(data, url)
            if !closed, projectIdentity == snapshot.projectID { status = options.format.title + " 내보내기 완료" }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if !closed, projectIdentity == snapshot.projectID { self.error = error.localizedDescription }
            return false
        }
    }

    func confirmDiscard() -> Bool {
        guard dirty else { return true }
        switch services.discardDecision() {
        case .saveAndContinue: save(); return !dirty
        case .discard: return true
        case .cancel: return false
        }
    }

    private func stopAndCleanAudio() {
        finishAssetHandover()
        for cached in preparedPlayers.values { cached.transport.stop() }
        for cached in inactivePlayers.values { cached.transport.stop() }
        inactivePlayers.removeAll()
        preparedPlayers.removeAll(); scheduledStart = nil
        player?.stop(); player = nil; playing = false
        for audio in [originalAudio, stemAudio].compactMap({ $0 }) { audio.resource.disposeScratch() }
        for resource in retiredStemResources.values { resource.disposeScratch() }
        retiredStemResources.removeAll()
        originalAudio = nil; stemAudio = nil; prepared = nil
    }
    func shutdown() {
        guard !closed else { return }
        flushSession()
        closed = true; startupPending = false
        externalOpenDidShutdown?(); externalOpenDidShutdown = nil
        externalOpenDidCancelLoad = nil
        clearPitchDetection()
        nativeTextObserver?.cancel(); nativeTextObserver = nil; memoSession = nil
        cancelLoading(); cancelAnalysis()
        busy = false
        autosaveTask?.cancel()
        analysisTask?.cancel(); timer?.invalidate(); stopAndCleanAudio()
        undoHistory.removeAll(); redoHistory.removeAll()
        if let demoURL { try? FileManager.default.removeItem(at: demoURL) }
    }
}
