import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: Workspace?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspace?.cancelLoading()
        guard workspace?.confirmDiscard() ?? true else { return .terminateCancel }
        workspace?.shutdown()
        return .terminateNow
    }
}

@main
struct RoughScoreApp: App {
    @StateObject private var workspace = Workspace(awaitsStartup: true)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("RoughScore", id: "main") {
            WorkspaceView(workspace: workspace)
                .frame(minWidth: 1120, minHeight: 740)
                .preferredColorScheme(.dark)
                .task { delegate.workspace = workspace; workspace.start() }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("채보 실행 취소") { workspace.undoEdit() }.keyboardShortcut("z").disabled(!workspace.canUndo)
                Button("채보 다시 실행") { workspace.redoEdit() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!workspace.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button("오디오 열기…") { workspace.importAudio() }.keyboardShortcut("o")
                    .disabled(workspace.busy || workspace.analyzing)
                Button("프로젝트 열기…") { workspace.openProject() }.keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(workspace.busy || workspace.analyzing)
                Button("프로젝트 저장…") { workspace.save() }.keyboardShortcut("s")
                    .disabled(workspace.busy)
                Button("TAB 텍스트 내보내기…") { workspace.exportText() }.keyboardShortcut("e", modifiers: [.command, .shift])
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
