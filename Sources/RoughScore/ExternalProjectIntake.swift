import Foundation

/// One native URL route, one pending cold-start request, and one modal/load owner.
/// Admission is not a validated load result; only the existing transaction can complete it.
@MainActor
final class ExternalProjectIntake {
    enum Admission { case queued, started, cancelled, rejected }
    enum Completion: Equatable { case opened, notOpened }
    private struct Request { let id = UUID(); let url: URL }
    private weak var workspace: Workspace?
    private var boundIdentity: ObjectIdentifier?
    private var pending: Request?
    private var requestID: UUID?
    private var closed = false
    private var terminating = false
    private(set) var task: Task<Bool, Never>?
    private(set) var lastCompletion: Completion?
    private(set) var lastRejection: String?
    var hasPendingRequest: Bool { pending != nil }
    var allowsWindowPresentation: Bool { !closed && !terminating && workspace?.isClosed != true }

    static func validate(_ urls: [URL]) throws -> URL {
        guard urls.count == 1 else { throw IntakeError("한 번에 프로젝트 하나만 열 수 있습니다. 파일 하나를 선택해 다시 시도하세요.") }
        let url = urls[0]
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw IntakeError("로컬 프로젝트 파일만 열 수 있습니다.")
        }
        let ext = url.pathExtension.lowercased()
        guard ["roughscore", "roughscorepkg"].contains(ext) else {
            throw IntakeError(".roughscore 파일 또는 .roughscorepkg 패키지를 선택하세요.")
        }
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) }
        catch { throw IntakeError("프로젝트가 없거나 읽을 수 없습니다. 파일 위치를 확인하세요.") }
        guard ext == "roughscore" ? values.isRegularFile == true : values.isDirectory == true else {
            throw IntakeError(".roughscore는 일반 파일, .roughscorepkg는 디렉터리 패키지여야 합니다.")
        }
        return url
    }

    @discardableResult
    func receive(_ urls: [URL]) -> Admission {
        guard !closed, !terminating, workspace?.isClosed != true else {
            return reject("종료 중이거나 종료된 작업 공간에서는 프로젝트를 열 수 없습니다.")
        }
        let url: URL
        do { url = try Self.validate(urls) }
        catch { return reject(error.localizedDescription) }
        guard pending == nil, requestID == nil else {
            return reject("이전 프로젝트 열기 요청이 진행 중입니다. 완료한 뒤 다시 시도하세요.")
        }
        // A new accepted request supersedes earlier feedback. Later rejected requests
        // keep their own message, including requests rejected before the first bind.
        lastRejection = nil
        workspace?.externalOpenError = nil
        let request = Request(url: url)
        guard let workspace else { pending = request; return .queued }
        return begin(request, workspace: workspace)
    }

    /// Repeated SwiftUI tasks bind the same owner without starting its lifecycle twice.
    func bind(_ owner: Workspace) {
        guard !closed, !owner.isClosed else { shutdown(); return }
        if let boundIdentity, boundIdentity != ObjectIdentifier(owner) {
            shutdown() // A queued/late request can never migrate to a replacement owner.
            owner.externalOpenError = "작업 공간이 바뀌어 외부 열기 요청을 취소했습니다."
            return
        }
        if boundIdentity == nil { owner.externalOpenError = lastRejection }
        boundIdentity = ObjectIdentifier(owner)
        workspace = owner
        owner.externalOpenDidShutdown = { [weak self] in self?.shutdown() }
        owner.externalOpenDidCancelLoad = { [weak self] in self?.cancelActiveLoad() }
        if let request = pending {
            pending = nil
            _ = begin(request, workspace: owner)
        } else if requestID == nil, !terminating { owner.start() }
    }

    private func begin(_ request: Request, workspace owner: Workspace) -> Admission {
        requestID = request.id // Before a native dirty/save alert can reenter.
        lastCompletion = nil
        let admission = owner.admitExternalProject(at: request.url) { [weak self, weak owner] in
            guard let self, let owner else { return false }
            return !self.closed && !self.terminating && self.requestID == request.id && self.workspace === owner && !owner.isClosed
        }
        switch admission {
        case .rejected(let message):
            if requestID == request.id { requestID = nil }
            return reject(message)
        case .cancelled:
            if requestID == request.id { requestID = nil }
            lastCompletion = .notOpened
            return .cancelled
        case .loading(let loading):
            let completion = Task { [weak self, weak owner] in
                let opened = await loading.value
                guard let self, let owner, !self.closed, !self.terminating,
                      self.workspace === owner, !owner.isClosed, self.requestID == request.id else { return false }
                self.requestID = nil; self.task = nil
                self.lastCompletion = opened ? .opened : .notOpened
                // Load failure details stay in Workspace.error; no focus/reset on failure.
                if !opened { owner.externalOpenError = "프로젝트를 열지 못했습니다. 이전 작업을 유지했습니다. " + (owner.error ?? "열기가 취소되었습니다.") }
                return opened
            }
            task = completion
            return .started
        }
    }

    private func reject(_ message: String) -> Admission {
        lastRejection = message
        workspace?.externalOpenError = message
        return .rejected
    }

    func beginTermination() {
        terminating = true; pending = nil; requestID = nil
        task?.cancel(); task = nil
    }
    private func cancelActiveLoad() {
        requestID = nil; task?.cancel(); task = nil; lastCompletion = .notOpened
    }
    func cancelTermination() { if !closed { terminating = false } }
    func shutdown() {
        let hadLoad = task != nil
        closed = true; pending = nil; requestID = nil
        task?.cancel(); task = nil
        if hadLoad { workspace?.cancelLoading() }
    }

    private struct IntakeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
