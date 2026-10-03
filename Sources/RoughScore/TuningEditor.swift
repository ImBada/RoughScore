import RoughScoreCore
import SwiftUI

struct TuningControl: View {
    @ObservedObject var workspace: Workspace
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            Label(workspace.project.tuningDisplay, systemImage: "slider.horizontal.3")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }.buttonStyle(.borderless).disabled(!workspace.canMutateNotes)
            .help("튜닝/카포 · L/R 공통 · 기존 운지 유지")
            .popover(isPresented: $open) {
                TuningEditor(workspace: workspace) { open = false; workspace.requestKeyboardFocus?() }
            }
    }
}

/// Drafts stay local until all six pitches and capo validate together.
struct TuningEditor: View {
    @ObservedObject var workspace: Workspace
    var dismiss: () -> Void = {}
    @State private var pitches = Array(repeating: "", count: 6)
    @State private var capo = "0"
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("튜닝 · 카포").font(.headline)
            Text("L/R 공통 · MIDI 0–127 · 프렛은 카포 기준 0–24\n적용해도 기존 시간/줄/프렛은 유지됩니다.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("Standard") { preset(.standard) }
                Button("Drop D") { preset(.dropD) }
                Text("또는 직접 MIDI 입력").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(0..<6, id: \.self) { index in
                HStack {
                    Text("\(index + 1)번 줄").frame(width: 55, alignment: .leading)
                    TextField("open MIDI", text: $pitches[index])
                        .accessibilityIdentifier("tuning-open-\(index + 1)")
                        .frame(width: 70).textFieldStyle(.roundedBorder)
                    Text(Int(pitches[index]).map(TuningDefinition.pitchName) ?? "옥타브 미확정")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("카포").frame(width: 55, alignment: .leading)
                TextField("0–24", text: $capo).accessibilityIdentifier("tuning-capo")
                    .frame(width: 70).textFieldStyle(.roundedBorder)
            }
            if workspace.project.resolvedTuning == nil {
                Text("이전 튜닝의 옥타브는 알 수 없습니다. 프리셋 또는 여섯 MIDI를 명시해 주세요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Button("취소") { dismiss() }
                Spacer()
                Button("적용 · 기존 운지 유지") { apply() }.disabled(!workspace.canMutateNotes)
            }
        }.font(.system(size: 12)).padding(18).frame(width: 380)
            .onAppear {
                if let tuning = workspace.project.resolvedTuning {
                    pitches = tuning.openMIDIPitches.map(String.init); capo = String(tuning.capo)
                }
            }
    }
    private func preset(_ tuning: TuningDefinition) {
        pitches = tuning.openMIDIPitches.map(String.init); message = ""
    }
    private func apply() {
        let values = pitches.compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard values.count == 6, let capoValue = Int(capo.trimmingCharacters(in: .whitespacesAndNewlines)),
              workspace.setTuning(openMIDIPitches: values, capo: capoValue) else {
            message = "여섯 MIDI 0–127, 카포 0–24, MIDI+카포 ≤127이어야 합니다."
            return
        }
        dismiss()
    }
}

struct PitchAlternatives: View {
    @ObservedObject var workspace: Workspace
    let event: TabEvent
    @State private var expanded = false
    @State private var midiText = ""
    @State private var preferenceText = ""

    private var resolution: FingeringResolution? {
        guard !midiText.isEmpty else { return nil }
        guard let midi = Int(midiText) else { return .invalidPitch }
        let preference: Int?
        if preferenceText.isEmpty { preference = nil }
        else if let value = Int(preferenceText) { preference = value }
        else { return .invalidPreference }
        return workspace.fingerings(midi: midi, preferredFret: preference, eventID: event.id)
    }
    var body: some View {
        DisclosureGroup("음고 / 다른 운지 · 선택 사항", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(event.fret.flatMap { workspace.project.soundingMIDI(string: event.string, fret: $0) }
                    .map { "현재 \(TuningDefinition.pitchName($0)) · MIDI \($0)" } ?? "현재 음고 미확정")
                    .foregroundStyle(.secondary)
                HStack {
                    Text("MIDI")
                    TextField("0–127", text: $midiText).accessibilityIdentifier("fingering-midi")
                    Text("선호 프렛")
                    TextField("선택", text: $preferenceText).accessibilityIdentifier("fingering-preference")
                }.textFieldStyle(.roundedBorder)
                HStack {
                    Button(workspace.detectingPitch ? "추정 중…" : "이 위치의 단음 추정") { workspace.detectSelectedPitch() }
                        .disabled(workspace.prepared == nil || workspace.detectingPitch || !workspace.canMutateNotes)
                    if let pitch = workspace.detectedPitch, let midi = pitch.nearestMIDI {
                        Button("MIDI \(midi) 후보 보기") { midiText = String(midi) }
                            .help("\(String(format: "%.1f", pitch.frequencyHz)) Hz · 추정값을 반음으로 반올림")
                    }
                }
                if !workspace.pitchDetectionMessage.isEmpty { Text(workspace.pitchDetectionMessage).foregroundStyle(.secondary) }
                if let resolution {
                    Text(explanation(resolution)).foregroundStyle(.secondary)
                    ForEach(resolution.candidates, id: \.string) { candidate in
                        Button("\(candidate.string)번 / \(candidate.fret)프렛 · 선택") {
                            if let midi = Int(midiText), workspace.chooseFingering(midi: midi, string: candidate.string,
                                fret: candidate.fret, eventID: event.id) { workspace.requestKeyboardFocus?() }
                        }.disabled(!workspace.canMutateNotes)
                    }
                }
                Text("같은 L/R의 앞뒤 운지와 선호 위치 순 · 자동 확정 없음 · 선택 후 ⌘Z 한 번")
                    .foregroundStyle(.secondary)
            }.padding(.top, 6)
        }.font(.system(size: 10))
            .onAppear {
                midiText = event.fret.flatMap { workspace.project.soundingMIDI(string: event.string, fret: $0) }.map(String.init) ?? ""
            }
    }
    private func explanation(_ value: FingeringResolution) -> String {
        switch value {
        case .resolved(let candidates): candidates.isEmpty ? "이 음고의 운지 없음 · 프렛 0–24" : "\(candidates.count)개 운지 · 직접 선택"
        case .unresolvedTuning: "튜닝/옥타브 미확정 · 튜닝 설정 필요"
        case .invalidTuning: "튜닝 값이 올바르지 않습니다"
        case .invalidPitch: "MIDI 정수 0–127을 입력하세요"
        case .invalidPreference: "선호 프렛은 0–24 또는 빈칸"
        case .invalidContext: "선택한 음/위치 확인 필요"
        }
    }
}
