import AppKit
import RoughScoreCore
import SwiftUI

@MainActor
enum NoteAccessibility {
    static func label(_ event: TabEvent, workspace: Workspace) -> String {
        let selection = workspace.selectedID == event.id ? "선택됨 · 주 선택" :
            (workspace.selectedIDs.contains(event.id) ? "선택됨" : "선택 안 됨")
        return "\(event.lane.title) · 원곡 \(String(event.time))초 · \(event.string)번 줄 · " +
            (event.fret.map { "\($0)프렛" } ?? "음 미확인") + " · " +
            (event.length?.title ?? "길이 미지정") + " · " +
            (event.tentative ? "잠정" : "잠정 아님") + " · " + selection +
            (workspace.positionMagnetTargetID == event.id ? " · 마그넷 붙음" : "")
    }
    static func availability(_ id: UUID, workspace: Workspace) -> () -> Bool {
        let identity = workspace.editorIdentity
        return { [weak workspace] in workspace?.canAccessNote(id: id, editorID: identity) == true }
    }
    static func actions(_ id: UUID, workspace: Workspace) -> [(String, () -> Bool)] {
        let identity = workspace.editorIdentity
        guard let event = workspace.project.events.first(where: { $0.id == id }), workspace.canMutateNotes else { return [] }
        var result: [(String, () -> Bool)] = []
        for (name, delta) in [("이 음 50ms 앞쪽", -0.05), ("이 음 10ms 앞쪽", -0.01),
                              ("이 음 10ms 뒤쪽", 0.01), ("이 음 50ms 뒤쪽", 0.05)] {
            guard event.time + delta >= 0, event.time + delta < workspace.project.duration else { continue }
            result.append((name, { [weak workspace] in
                workspace?.moveAccessibleNote(id: id, editorID: identity, timeDelta: delta) == true
            }))
        }
        for (name, delta) in [("이 음 위 줄로", -1), ("이 음 아래 줄로", 1)] {
            guard (1...6).contains(event.string + delta) else { continue }
            result.append((name, { [weak workspace] in
                workspace?.moveAccessibleNote(id: id, editorID: identity, stringDelta: delta) == true
            }))
        }
        return result
    }
}

/// Native controls explicitly include buttons in the key loop, independent of OS keyboard-navigation preferences.
@MainActor
final class EditorNavigationButton: NSButton {
    var invoke: (() -> Void)?
    weak var navigation: EditorNavigationView?
    weak var keyLoop: NativeEditorKeyLoop?
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }
    override func keyDown(with event: NSEvent) {
        if navigation?.traverse(event, from: self) == true { return }
        if event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           keyLoop?.advance(from: self, backwards: event.modifierFlags.contains(.shift)) == true { return }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           event.keyCode == 36 || event.keyCode == 49 { invoke?(); return }
        super.keyDown(with: event)
    }
    @objc func run(_ sender: Any?) { invoke?() }
}

@MainActor
final class EditorNavigationField: NSTextField {
    weak var navigation: EditorNavigationView?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if navigation?.reenter(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class EditorNavigationMenu: NSPopUpButton {
    weak var navigation: EditorNavigationView?
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }
    override func keyDown(with event: NSEvent) {
        if navigation?.traverse(event, from: self) == true { return }
        super.keyDown(with: event)
    }
}

@MainActor
final class EditorNavigationView: NSView, NSTextFieldDelegate {
    let owner = UUID()
    weak var workspace: Workspace?
    var identity: UUID?
    let cursorField = EditorNavigationField()
    let intervalField = EditorNavigationField()
    let input = EditorNavigationButton()
    let notes = EditorNavigationButton()
    let tuning = EditorNavigationButton()
    let settings = EditorNavigationMenu(frame: .zero, pullsDown: true)
    var openNotes: (() -> Void)?
    var openTuning: (() -> Void)?
    private var displayedCursor = ""
    private var displayedInterval = ""
    private var cursorSnapshot = 0.0
    private var controls: [NSControl] { [cursorField, input, notes, settings, intervalField, tuning] }
    private var live: Workspace? {
        guard let workspace, workspace.canEdit, workspace.editorIdentity == identity, workspace.controlFocusOwner == owner else { return nil }
        return workspace
    }
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        func field(_ field: EditorNavigationField, _ name: String, _ id: String) {
            field.delegate = self; field.navigation = self; field.identifier = .init(id)
            field.setAccessibilityLabel(name); field.placeholderString = name
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            addSubview(field)
        }
        field(cursorField, "편집 커서 · 원곡 초", "editing-cursor")
        field(intervalField, "입력 간격 · 초", "entry-interval")
        for (button, title, id) in [(input, "TAB 입력 ⌘↵", "tab-input"), (notes, "음 목록…", "note-list"), (tuning, "튜닝 / 카포…", "editor-tuning")] {
            button.title = title; button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 11)
            button.target = button; button.action = #selector(EditorNavigationButton.run(_:))
            button.navigation = self; button.identifier = .init(id); button.setAccessibilityLabel(title)
            addSubview(button)
        }
        input.invoke = { [weak self] in self?.live?.requestKeyboardFocus?() }
        notes.invoke = { [weak self] in guard self?.live?.canEdit == true else { return }; self?.openNotes?() }
        tuning.invoke = { [weak self] in guard self?.live?.canMutateNotes == true else { return }; self?.openTuning?() }
        settings.navigation = self; settings.identifier = .init("editor-display-settings")
        settings.setAccessibilityLabel("표시 설정"); addSubview(settings)
        // Real named key views; bridge escape uses the endpoints below.
        for (index, control) in controls.enumerated() { control.nextKeyView = controls[(index + 1) % controls.count] }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let widths: [CGFloat] = [140, 110, 82, 100, 100, 116]
        var x: CGFloat = 0
        for (control, width) in zip(controls, widths) { control.frame = NSRect(x: x, y: 0, width: width, height: 32); x += width + 8 }
    }
    func update(_ workspace: Workspace) {
        self.workspace = workspace; identity = workspace.editorIdentity
        workspace.controlFocusOwner = owner
        let identity = workspace.editorIdentity
        workspace.requestControlFocus = { [weak self, weak workspace] backwards in
            guard let self, let workspace, workspace.canEdit, workspace.editorIdentity == identity,
                  workspace.controlFocusOwner == self.owner, let window = self.window else { return false }
            let destinations = backwards ? Array(self.controls.reversed()) : self.controls
            for control in destinations where control.isEnabled {
                if window.makeFirstResponder(control) { return true }
            }
            return false
        }
        if cursorField.currentEditor() == nil {
            cursorSnapshot = workspace.cursor; displayedCursor = String(format: "%.6f", cursorSnapshot)
            cursorField.stringValue = displayedCursor
        }
        cursorField.setAccessibilityValueDescription("원곡 \(String(workspace.cursor))초 · \(workspace.lane.title) · \(workspace.activeString)번 줄")
        if intervalField.currentEditor() == nil {
            displayedInterval = String(workspace.entryInterval); intervalField.stringValue = displayedInterval
        }
        for control in controls { control.isEnabled = workspace.canEdit }
        cursorField.isEnabled = workspace.canMutateNotes; intervalField.isEnabled = workspace.canMutateNotes
        tuning.isEnabled = workspace.canMutateNotes; notes.isEnabled = workspace.canMutateNotes
        let menu = NSMenu()
        menu.addItem(withTitle: "표시 설정", action: nil, keyEquivalent: "")
        for (index, title, enabled, checked) in [
            (0, "악보 보기", true, workspace.scoreView), (1, "음표 길이", true, workspace.showLengths),
            (2, "L/R 함께", true, workspace.showBothLanes), (3, "악보 파형", true, workspace.showScoreWaveforms),
            (4, "재생 따라가기", true, workspace.followScore), (5, "한 줄 4 / 8마디", true, workspace.measuresPerSystem == 8),
            (6, "페이지 맞춤 전환", workspace.scoreView && workspace.requestScoreFitPageToggle != nil, false),
            (7, "이전 악보 페이지", workspace.scoreView && workspace.displayedScorePage > 0, false),
            (8, "다음 악보 페이지", workspace.scoreView && workspace.displayedScorePage < workspace.scoreLayout.pageCount - 1, false)] {
            let item = NSMenuItem(title: title, action: #selector(setting(_:)), keyEquivalent: "")
            item.tag = index; item.target = self; item.isEnabled = enabled; item.state = checked ? .on : .off; menu.addItem(item)
        }
        settings.menu = menu
    }
    @objc private func setting(_ item: NSMenuItem) {
        guard let workspace = live, workspace.canEdit else { return }
        switch item.tag {
        case 0: workspace.scoreView.toggle()
        case 1: workspace.showLengths.toggle()
        case 2: workspace.showBothLanes.toggle()
        case 3: workspace.showScoreWaveforms.toggle()
        case 4: workspace.followScore.toggle()
        case 5: workspace.measuresPerSystem = workspace.measuresPerSystem == 4 ? 8 : 4
        case 6: workspace.requestScoreFitPageToggle?()
        case 7: workspace.browseScorePage(workspace.displayedScorePage - 1)
        case 8: workspace.browseScorePage(workspace.displayedScorePage + 1)
        default: break
        }
    }
    func reenter(_ event: NSEvent) -> Bool {
        guard event.keyCode == 36, event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option), let workspace = live else { return false }
        window?.makeFirstResponder(input) // Intentionally ends a native field edit before TAB entry.
        workspace.requestKeyboardFocus?(); return true
    }
    func traverse(_ event: NSEvent, from view: NSView) -> Bool {
        if reenter(event) { return true }
        guard event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        return focusAdjacent(from: view, backwards: event.modifierFlags.contains(.shift))
    }
    @discardableResult private func focusAdjacent(from view: NSView, backwards: Bool) -> Bool {
        guard let index = controls.firstIndex(where: { $0 === view }), let window else { return false }
        for step in 1...controls.count {
            let candidate = controls[(index + (backwards ? -step : step) + controls.count) % controls.count]
            if candidate.isEnabled, window.makeFirstResponder(candidate) { return true }
        }
        return false
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Only native Tab/Shift-Tab navigation; typing, marked text, caret and clipboard stay native.
        if selector == #selector(NSResponder.insertTab(_:)) { return focusAdjacent(from: control, backwards: false) }
        if selector == #selector(NSResponder.insertBacktab(_:)) { return focusAdjacent(from: control, backwards: true) }
        if selector == #selector(NSResponder.insertNewline(_:)) { apply(control); return true }
        return false
    }
    func controlTextDidEndEditing(_ obj: Notification) { if let control = obj.object as? NSControl { apply(control) } }
    private func apply(_ control: NSControl) {
        guard let workspace = live, workspace.canMutateNotes else { return }
        if control === cursorField, cursorField.stringValue != displayedCursor,
           let time = Double(cursorField.stringValue.replacingOccurrences(of: ",", with: ".")), time != cursorSnapshot {
            workspace.seekForEditing(time, requestFocus: false)
            cursorSnapshot = workspace.cursor; displayedCursor = String(format: "%.6f", workspace.cursor)
        } else if control === intervalField, intervalField.stringValue != displayedInterval,
                  let value = Double(intervalField.stringValue) {
            _ = workspace.setEntryInterval(value); displayedInterval = String(workspace.entryInterval)
        }
    }
}

struct EditorNavigationControls: NSViewRepresentable {
    @ObservedObject var workspace: Workspace
    let openNotes: () -> Void
    let openTuning: () -> Void
    func makeNSView(context: Context) -> EditorNavigationView { EditorNavigationView() }
    func updateNSView(_ view: EditorNavigationView, context: Context) {
        view.openNotes = openNotes; view.openTuning = openTuning; view.update(workspace)
    }
    static func dismantleNSView(_ view: EditorNavigationView, coordinator: ()) {
        if let workspace = view.workspace, workspace.controlFocusOwner == view.owner {
            workspace.requestControlFocus = nil; workspace.controlFocusOwner = nil
        }
        view.workspace = nil; view.openNotes = nil; view.openTuning = nil
    }
}

/// One adjustable native element per map/waveform, rather than peak/Canvas speech children.
@MainActor
final class EditingCursorAXView: NSView {
    weak var workspace: Workspace?
    var identity: UUID?
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // Pointer gestures belong to the canvas below.
    override func isAccessibilityEnabled() -> Bool { workspace?.editorIdentity == identity && workspace?.canMutateNotes == true }
    override func accessibilityValue() -> Any? {
        guard let workspace, workspace.editorIdentity == identity else { return nil }; return workspace.cursor
    }
    override func accessibilityValueDescription() -> String? {
        guard let workspace, workspace.editorIdentity == identity else { return nil }
        return "원곡 \(String(workspace.cursor))초 · \(workspace.lane.title) · \(workspace.activeString)번 줄"
    }
    private func adjust(_ delta: Double) -> Bool {
        guard let workspace, workspace.editorIdentity == identity, workspace.canMutateNotes,
              let time = TimeBounds.clamp(workspace.cursor + delta, duration: workspace.project.duration), time != workspace.cursor else { return false }
        workspace.seekForEditing(time, requestFocus: false); return true
    }
    override func accessibilityPerformIncrement() -> Bool { adjust(0.05) }
    override func accessibilityPerformDecrement() -> Bool { adjust(-0.05) }
}
struct EditingCursorAXSurface: NSViewRepresentable {
    @ObservedObject var workspace: Workspace
    let name: String
    func makeNSView(context: Context) -> EditingCursorAXView { EditingCursorAXView() }
    static func dismantleNSView(_ view: EditingCursorAXView, coordinator: ()) { view.workspace = nil; view.identity = nil }
    func updateNSView(_ view: EditingCursorAXView, context: Context) {
        view.workspace = workspace; view.identity = workspace.editorIdentity
        view.setAccessibilityElement(true); view.setAccessibilityRole(.slider)
        view.setAccessibilityLabel(name + " · 편집 커서 · 50ms 조절")
        view.setAccessibilityIdentifier(name == "곡 전체 지도" ? "song-map-cursor" : "waveform-cursor")
        view.setAccessibilityMinValue(0); view.setAccessibilityMaxValue(workspace.project.duration.nextDown)
    }
}

@MainActor
final class AccessibleNoteRow: NSButton {
    var press: (() -> Bool)?
    weak var list: AccessibleNoteListView?
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }
    @objc func invoke(_ sender: Any?) { _ = press?() }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; return press?() ?? false }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 48: list?.advance(from: self, backwards: event.modifierFlags.contains(.shift))
        case 125: list?.advance(from: self, backwards: false)
        case 126: list?.advance(from: self, backwards: true)
        case 36, 49: _ = accessibilityPerformPress()
        case 53: list?.cancel?()
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
final class AccessibleNoteListView: NSScrollView {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let content = Document()
    private(set) var rows: [AccessibleNoteRow] = []
    var dismiss: (() -> Void)?
    var cancel: (() -> Void)?
    private var focusedOnce = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        documentView = content; hasVerticalScroller = true; drawsBackground = false
        setAccessibilityLabel("음 목록 · 원곡 시간 · 위아래 또는 Tab으로 이동 · Enter 선택 · Esc 닫기")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(events: [TabEvent], workspace: Workspace) {
        let identity = workspace.editorIdentity
        let previous = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.identifier.map { ($0.rawValue, row) } })
        rows = events.compactMap { snapshot in
            guard let event = workspace.project.events.first(where: { $0.id == snapshot.id }) else { return nil }
            let id = "note-list-" + event.id.uuidString
            let row = previous[id] ?? AccessibleNoteRow()
            row.identifier = .init(id); row.setAccessibilityIdentifier("note-" + event.id.uuidString)
            row.title = NoteAccessibility.label(event, workspace: workspace) + (event.memo.isEmpty ? "" : " · " + event.memo)
            row.setAccessibilityLabel(NoteAccessibility.label(event, workspace: workspace))
            row.setAccessibilityValue(event.memo)
            row.setAccessibilitySelected(workspace.selectedIDs.contains(event.id))
            row.setAccessibilityCustomActions(NoteAccessibility.actions(event.id, workspace: workspace).map { NSAccessibilityCustomAction(name: $0.0, handler: $0.1) })
            row.isEnabled = workspace.canAccessNote(id: event.id, editorID: identity)
            row.font = .systemFont(ofSize: 11); row.bezelStyle = .rounded; row.alignment = .left
            row.cell?.wraps = true; row.target = row; row.action = #selector(AccessibleNoteRow.invoke(_:)); row.list = self
            row.press = { [weak workspace, weak self] in
                guard let workspace, workspace.canAccessNote(id: event.id, editorID: identity),
                      let actual = workspace.project.events.first(where: { $0.id == event.id }) else { return false }
                workspace.select(actual); self?.dismiss?(); return true
            }
            if row.superview == nil { content.addSubview(row) }
            return row
        }
        for row in previous.values where !rows.contains(where: { $0 === row }) { row.removeFromSuperview(); row.press = nil }
        for (index, row) in rows.enumerated() { row.nextKeyView = rows[(index + 1) % rows.count] }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = max(100, contentView.bounds.width)
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(contentView.bounds.height, CGFloat(rows.count) * 52))
        for (index, row) in rows.enumerated() { row.frame = NSRect(x: 4, y: CGFloat(index) * 52 + 2, width: width - 8, height: 48) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.focusedOnce, let window = self.window, let row = self.rows.first(where: { $0.isEnabled }) else { return }
            self.focusedOnce = window.makeFirstResponder(row)
        }
    }
    func advance(from row: AccessibleNoteRow, backwards: Bool) {
        guard let index = rows.firstIndex(where: { $0 === row }), !rows.isEmpty else { return }
        for step in 1...rows.count {
            let next = rows[(index + (backwards ? -step : step) + rows.count) % rows.count]
            if next.isEnabled { window?.makeFirstResponder(next); next.scrollToVisible(next.bounds); return }
        }
    }
}
struct AccessibleNoteList: NSViewRepresentable {
    @ObservedObject var workspace: Workspace
    let events: [TabEvent]
    let dismiss: () -> Void
    func makeNSView(context: Context) -> AccessibleNoteListView { AccessibleNoteListView() }
    func updateNSView(_ view: AccessibleNoteListView, context: Context) { view.dismiss = dismiss; view.cancel = { dismiss(); _ = workspace.requestControlFocus?(false) }; view.update(events: events, workspace: workspace) }
    static func dismantleNSView(_ view: AccessibleNoteListView, coordinator: ()) {
        view.dismiss = nil; view.cancel = nil; for row in view.rows { row.press = nil; row.setAccessibilityCustomActions([]) }
    }
}

/// Reuses the native button responder for the small tuning popover's explicit controls.
struct EditorActionButton: NSViewRepresentable {
    let title: String
    let identifier: String
    let enabled: Bool
    var keyLoop: NativeEditorKeyLoop? = nil
    let action: () -> Void
    func makeNSView(context: Context) -> EditorNavigationButton {
        let button = EditorNavigationButton(); button.bezelStyle = .rounded
        button.target = button; button.action = #selector(EditorNavigationButton.run(_:)); return button
    }
    func updateNSView(_ button: EditorNavigationButton, context: Context) {
        button.title = title; button.identifier = .init(identifier); button.setAccessibilityLabel(title)
        button.isEnabled = enabled; button.invoke = action; button.font = .systemFont(ofSize: 11)
        button.keyLoop = keyLoop; keyLoop?.register(button, id: identifier)
    }
    static func dismantleNSView(_ button: EditorNavigationButton, coordinator: ()) {
        if let id = button.identifier?.rawValue { button.keyLoop?.unregister(button, id: id) }
        button.invoke = nil; button.keyLoop = nil
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorNavigationButton, context: Context) -> CGSize? { nsView.intrinsicContentSize }
}

@MainActor
final class NativeEditorKeyLoop {
    let order: [String]
    private let members = NSMapTable<NSString, NSControl>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    private var initiallyFocused = false
    init(order: [String]) { self.order = order }
    func register(_ control: NSControl, id: String) { members.setObject(control, forKey: id as NSString) }
    func unregister(_ control: NSControl, id: String) {
        if members.object(forKey: id as NSString) === control { members.removeObject(forKey: id as NSString) }
    }
    func focusInitial(_ control: NSControl) {
        DispatchQueue.main.async { [weak self, weak control] in
            guard let self, !self.initiallyFocused, let control, let window = control.window else { return }
            self.initiallyFocused = window.makeFirstResponder(control)
        }
    }
    @discardableResult func advance(from control: NSControl, backwards: Bool) -> Bool {
        guard let id = control.identifier?.rawValue, let index = order.firstIndex(of: id), let window = control.window else { return false }
        for step in 1...order.count {
            let id = order[(index + (backwards ? -step : step) + order.count) % order.count]
            if let next = members.object(forKey: id as NSString), next.isEnabled, window.makeFirstResponder(next) { return true }
        }
        return false
    }
}

@MainActor
final class EditorDraftTextField: NSTextField, NSTextFieldDelegate {
    weak var keyLoop: NativeEditorKeyLoop?
    var change: ((String) -> Void)?
    func controlTextDidChange(_ obj: Notification) { change?(stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if let flags = NSApp.currentEvent?.modifierFlags, !flags.intersection([.command, .control, .option]).isEmpty { return false }
        if selector == #selector(NSResponder.insertTab(_:)) { return keyLoop?.advance(from: self, backwards: false) ?? false }
        if selector == #selector(NSResponder.insertBacktab(_:)) { return keyLoop?.advance(from: self, backwards: true) ?? false }
        return false
    }
}

/// Local draft text only. Unrelated publications never replace an active editor or marked text.
struct EditorDraftField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let label: String
    let identifier: String
    let keyLoop: NativeEditorKeyLoop
    var initiallyFocused = false
    func makeNSView(context: Context) -> EditorDraftTextField {
        let field = EditorDraftTextField(); field.delegate = field; field.isEditable = true; field.isSelectable = true
        field.bezelStyle = .roundedBezel; field.isBezeled = true; return field
    }
    func updateNSView(_ field: EditorDraftTextField, context: Context) {
        field.identifier = .init(identifier); field.setAccessibilityIdentifier(identifier); field.setAccessibilityLabel(label)
        field.placeholderString = placeholder; field.keyLoop = keyLoop; keyLoop.register(field, id: identifier)
        field.change = { text = $0 }
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
        if initiallyFocused { keyLoop.focusInitial(field) }
    }
    static func dismantleNSView(_ field: EditorDraftTextField, coordinator: ()) {
        if let id = field.identifier?.rawValue { field.keyLoop?.unregister(field, id: id) }
        field.change = nil; field.keyLoop = nil
    }
}
