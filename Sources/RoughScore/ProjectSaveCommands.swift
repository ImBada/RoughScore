import SwiftUI

/// Shared native File menu and visible toolbar menu; each action states its resource policy.
struct ProjectSaveCommands: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        Button("다른 이름으로 저장 · 링크…") { workspace.saveAs() }
            .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!workspace.canSave)
        Button("다른 이름으로 저장 · 오디오 포함…") { workspace.saveAs(format: .collected) }
            .disabled(!workspace.canSave)
        Button("사본 저장 · 링크…") { workspace.saveCopy() }
            .keyboardShortcut("s", modifiers: [.command, .option]).disabled(!workspace.canSave)
        Button("사본 저장 · 오디오 포함…") { workspace.saveCopy(format: .collected) }
            .disabled(!workspace.canSave)
    }
}

/// A native pull-down keeps the visible save choices available through AppKit actions and AX.
struct ProjectSaveMenu: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        BulkActionMenu(title: "다른 이름/사본", identifier: "project-save-menu", enabled: workspace.canSave, items: [
            .init(title: "다른 이름으로 저장 · 링크…", action: { workspace.saveAs() }),
            .init(title: "다른 이름으로 저장 · 오디오 포함…", action: { workspace.saveAs(format: .collected) }),
            .init(title: "사본 저장 · 링크…", action: { workspace.saveCopy() }),
            .init(title: "사본 저장 · 오디오 포함…", action: { workspace.saveCopy(format: .collected) })
        ])
    }
}
