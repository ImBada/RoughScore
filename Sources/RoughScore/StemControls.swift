import RoughScoreCore
import SwiftUI

/// The sidebar uses the same native controls exercised by disposable hidden hosts.
struct StemControls: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("기타 스템", systemImage: "waveform").font(.system(size: 12, weight: .medium))
            Text(workspace.stemConnection).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            GuitarSeparationControl(workspace: workspace)
            BulkActionButton(title: workspace.project.stemAsset == nil ? "스템 연결…" : "스템 다시 연결…",
                identifier: "stem-attach", enabled: workspace.canLoad && workspace.project.originalAsset != nil) { workspace.importStem() }
            HStack {
                BulkActionButton(title: "원곡", identifier: "stem-original",
                    enabled: workspace.canLoad && workspace.assetRole != .original) { workspace.switchAsset(.original) }
                BulkActionButton(title: "Stem", identifier: "stem-audition",
                    enabled: workspace.canLoad && workspace.project.stemAsset != nil && workspace.assetRole != .importedGuitarStem) {
                    workspace.switchAsset(.importedGuitarStem)
                }
            }
            if let stem = workspace.project.stemAsset {
                StemOffsetControl(workspace: workspace, offset: stem.originalTimeOffset)
                BulkActionButton(title: "스템 연결 해제", identifier: "stem-detach", enabled: workspace.canLoad) { workspace.detachStem() }
            }
        }.padding(12).background(Palette.elevated.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StemOffsetControl: View {
    @ObservedObject var workspace: Workspace
    let offset: Double
    @State private var text = ""
    private var value: Double? {
        guard let value = Double(text), value.isFinite, abs(value) <= 86_400 else { return nil }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("오프셋 · 원곡 = 파일 초 + 값").font(.system(size: 9))
            HStack {
                TextField("offset seconds", text: $text).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("스템 오프셋 · 초").accessibilityIdentifier("stem-offset")
                BulkActionButton(title: "적용", identifier: "stem-offset-apply",
                    enabled: value != nil && value != offset && workspace.canLoad) {
                    if let value { _ = workspace.setStemOffset(value) }
                }
            }
            Text("250ms 패딩: -0.250 · 자동 정렬 없음").font(.system(size: 9)).foregroundStyle(Palette.secondary)
        }.onAppear { text = String(format: "%.6f", offset) }
         .onChange(of: offset) { _, value in text = String(format: "%.6f", value) }
    }
}

/// On-device separation: progress + cancel while running, otherwise one button or install hint.
private struct GuitarSeparationControl: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        if let progress = workspace.separationProgress {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress) { Text("기타 분리 중 · \(Int(progress * 100))%").font(.system(size: 10)) }
                    .accessibilityIdentifier("guitar-separation-progress")
                BulkActionButton(title: "분리 취소", identifier: "guitar-separation-cancel", enabled: true) {
                    workspace.cancelGuitarSeparation()
                }
            }
        } else if workspace.guitarSeparatorInstalled {
            BulkActionButton(title: "원곡에서 기타 분리", identifier: "guitar-separation-start",
                             enabled: workspace.canSeparateGuitar) { workspace.separateGuitar() }
                .help("BS-RoFormer로 원곡의 기타를 기기에서 분리해 스템으로 연결합니다. 원곡과 TAB은 바뀌지 않습니다.")
        } else {
            Text("자동 분리 모델 미설치 · scripts/separation/install-guitar-separator.sh")
                .font(.system(size: 9)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
