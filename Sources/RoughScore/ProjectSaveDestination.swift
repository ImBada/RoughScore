import AppKit
import UniformTypeIdentifiers
import RoughScoreCore

/// The panel receives explicit intent and format; cancellation returns no destination.
struct ProjectSaveRequest: Sendable, Equatable {
    enum Action: Sendable { case save, saveAs, saveCopy }
    enum Format: Sendable, CaseIterable { case linked, collected
        var fileExtension: String { self == .linked ? "roughscore" : PortableProjectPackage.fileExtension }
        var title: String { self == .linked ? "링크 프로젝트 (.roughscore)" : "오디오 포함 프로젝트 (.roughscorepkg)" }
        var contentType: UTType {
            UTType(filenameExtension: fileExtension) ?? (self == .linked ? .json : .package)
        }
    }
    let title: String
    let action: Action
    let format: Format

    @MainActor func choose() -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title + "." + format.fileExtension
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.title = action == .saveCopy ? "프로젝트 사본 저장" : "프로젝트 다른 이름으로 저장"
        panel.message = format == .collected
            ? "원곡과 스템을 복사해 함께 이동할 수 있는 프로젝트를 만듭니다. 사용자 원본은 그대로 유지됩니다."
            : "오디오는 외부 파일에 연결합니다. 함께 이동하려면 오디오 포함 형식을 선택하세요."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
