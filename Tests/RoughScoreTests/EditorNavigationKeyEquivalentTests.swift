import AppKit
import SwiftUI
import Testing
@testable import RoughScore

@MainActor @Suite(.serialized)
struct EditorNavigationKeyEquivalentTests {
    @Test(arguments: [false, true])
    func controlTabKeyEquivalentRoutesToNamedControlsBeforeNativeTraversal(backwards: Bool) throws {
        _ = NSApplication.shared
        var services = WorkspaceServices.isolatedCache()
        services.lastProject = { nil }; services.rememberProject = { _ in }
        let workspace = Workspace(services: services); defer { workspace.shutdown() }
        let host = NotePointerTests.Host(WorkspaceView(workspace: workspace), height: 900, width: 1440)
        defer { host.close() }
        let bridge = try #require(host.descendants().compactMap { $0 as? TabKeyboardView }.first)
        let controls = try #require(host.descendants().compactMap { $0 as? EditorNavigationView }.first)
        workspace.requestKeyboardFocus?(); host.settle()
        #expect(host.window.firstResponder === bridge)
        let project = workspace.project
        let flags: NSEvent.ModifierFlags = backwards ? [.control, .shift] : .control
        // Native Shift-Tab uses the backtab character, unlike a synthetic plain-tab event.
        let character = backwards ? String(UnicodeScalar(0x19)!) : "\t"
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 100, windowNumber: host.window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 48))
        #expect(host.window.performKeyEquivalent(with: event))
        host.settle()
        if backwards { #expect(host.window.firstResponder === controls.tuning) }
        else { #expect(host.window.firstResponder === controls.cursorField.currentEditor()) }
        #expect(!workspace.tabInputFocused && workspace.project == project && !workspace.canUndo)
        let returnEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 101, windowNumber: host.window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(host.window.performKeyEquivalent(with: returnEvent))
        host.settle(); #expect(host.window.firstResponder === bridge)
    }
}
