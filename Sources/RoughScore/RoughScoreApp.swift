import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) weak var workspace: Workspace?
    let externalProjects = ExternalProjectIntake()
    var showMainWindow: (() -> Void)?

    func bind(_ workspace: Workspace, showMainWindow: (() -> Void)? = nil) {
        self.workspace = workspace
        if let showMainWindow { self.showMainWindow = showMainWindow }
        externalProjects.bind(workspace)
    }
    // URL document delivery supersedes openFile/openFiles. It has no open/print reply contract.
    func application(_ application: NSApplication, open urls: [URL]) {
        _ = externalProjects.receive(urls)
        showMainWindow?()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        externalProjects.beginTermination()
        workspace?.cancelLoading()
        guard workspace?.confirmDiscard() ?? true else {
            externalProjects.cancelTermination()
            return .terminateCancel
        }
        externalProjects.shutdown()
        workspace?.shutdown()
        return .terminateNow
    }
}

@main
struct RoughScoreApp: App {
    @StateObject private var workspace: Workspace
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    init() { self.init(services: { .live }) }
    // Native QA can construct the same app owner with isolated cache/session/preferences
    // before Workspace initialization. Production has no environment-based override.
    init(services: @escaping @MainActor () -> WorkspaceServices) {
        _workspace = StateObject(wrappedValue: Workspace(services: services(), awaitsStartup: true))
    }
    var body: some Scene {
        Window("RoughScore", id: "main") {
            WorkspaceView(workspace: workspace)
                .frame(minWidth: 1120, minHeight: 740)
                .preferredColorScheme(.dark)
                .task {
                    delegate.bind(workspace, showMainWindow: {
                        openWindow(id: "main") // Reopen the same single Window if it was closed.
                        NSApp.activate(ignoringOtherApps: true)
                    })
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("실행 취소") { workspace.performUndo() }.keyboardShortcut("z").disabled(!workspace.canPerformUndo)
                Button("다시 실행") { workspace.performRedo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!workspace.canPerformRedo)
            }
            CommandGroup(after: .pasteboard) {
                Button("TAB 입력으로 돌아가기") { workspace.requestKeyboardFocus?() }
                    .keyboardShortcut(.return, modifiers: .command).disabled(!workspace.canEdit)
                Button("선택을 커서에 복제") { _ = workspace.duplicateSelection() }
                    .keyboardShortcut("d").disabled(!workspace.canUseTabClipboard || !workspace.canEditSelection)
            }
            CommandGroup(replacing: .newItem) {
                Button("오디오 열기…") { workspace.importAudio() }.keyboardShortcut("o")
                    .disabled(workspace.busy || workspace.analyzing)
                Button("프로젝트 열기…") { workspace.openProject() }.keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(workspace.busy || workspace.analyzing)
                Button("프로젝트 저장…") { workspace.save() }.keyboardShortcut("s")
                    .disabled(!workspace.canSave)
                ProjectSaveCommands(workspace: workspace)
                ScoreExportCommands(workspace: workspace)
            }
            CommandGroup(replacing: .printItem) {
                Button("인쇄…") { workspace.beginExport(.print) }.keyboardShortcut("p").disabled(!workspace.canExport)
            }
            CommandMenu("재생") {
                Button(workspace.playing ? "일시 정지" : "재생") { workspace.togglePlayback() }
                    .keyboardShortcut(.space, modifiers: []).disabled(workspace.prepared == nil)
                Button("루프 시작점 지정") { workspace.setLoopStart() }.keyboardShortcut("[", modifiers: [])
                Button("루프 끝점 지정") { workspace.setLoopEnd() }.keyboardShortcut("]", modifiers: [])
            }
        }
    }
}
