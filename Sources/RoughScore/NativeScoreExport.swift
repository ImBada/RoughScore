import AppKit
import PDFKit
import RoughScoreCore
import UniformTypeIdentifiers

struct ScoreExportServices: Sendable {
    var chooseDestination: @MainActor @Sendable (ScoreExportFormat, String) -> URL? = { format, title in
        let panel = NSSavePanel()
        let safe = title.map { "/:\n\r".contains($0) ? "_" : String($0) }.joined()
        panel.nameFieldStringValue = safe + "-TAB." + format.fileExtension
        panel.allowedContentTypes = [format == .pdf ? .pdf : format == .table ? .tabSeparatedText : .plainText]
        panel.title = format.title + " 내보내기"
        return panel.runModal() == .OK ? panel.url : nil
    }
    var write: @MainActor @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var print: @MainActor @Sendable (Data, ScoreRenderPlan.Settings) throws -> Bool = { data, settings in
        let (document, operation) = try NativeScorePrint.operation(data, settings: settings)
        return withExtendedLifetime(document) { operation.run() }
    }
}

@MainActor enum NativeScorePrint {
    static func operation(_ data: Data, settings: ScoreRenderPlan.Settings) throws -> (PDFDocument, NSPrintOperation) {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw ScoreExportError.renderingFailed }
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { throw ScoreExportError.renderingFailed }
        info.paperSize = NSSize(width: settings.paper.width, height: settings.paper.height)
        info.orientation = .portrait
        info.leftMargin = 0; info.rightMargin = 0; info.topMargin = 0; info.bottomMargin = 0
        info.isHorizontallyCentered = true; info.isVerticallyCentered = true
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: false)
        else { throw ScoreExportError.renderingFailed }
        operation.showsPrintPanel = true; operation.showsProgressPanel = true
        return (document, operation)
    }
}
