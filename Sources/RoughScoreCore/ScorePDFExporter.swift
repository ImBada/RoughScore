import Foundation
import CoreGraphics
import CoreText

/// Native CoreGraphics/CoreText PDF renderer. No app window, transport chrome,
/// audio load, global font installation, print dialog or project mutation.
public enum ScorePDFExporter {
    public static func data(for plan: ScoreRenderPlan) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { throw ScoreExportError.renderingFailed }
        var box = CGRect(x: 0, y: 0, width: plan.settings.paper.width, height: plan.settings.paper.height)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw ScoreExportError.renderingFailed }
        let height = plan.settings.paper.height, margin = plan.settings.margin
        for page in plan.pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
            context.setFillColor(CGColor(gray: 0.13, alpha: 1))
            var y = margin
            for title in plan.titleLines { draw(title, x: margin, top: y, size: 16, context: context, pageHeight: height); y += 20 }
            for line in plan.tuningLines { draw(line, x: margin, top: y, size: 8, context: context, pageHeight: height); y += 11 }
            draw("Original seconds [\(plan.range.start), \(plan.range.end)) - \(plan.lanes.map(\.rawValue).joined(separator: "/"))", x: margin, top: y + 2, size: 8, context: context, pageHeight: height)
            draw("? unknown fret; ~ tentative; blank/dashes untranscribed, never rests. #N identifies each separate note.", x: margin, top: y + 14, size: 8, context: context, pageHeight: height)
            for element in page.elements {
                switch element {
                case .text(let block):
                    for (i, line) in block.lines.enumerated() {
                        draw(line, x: margin, top: block.top + Double(i) * block.fontSize * 1.45,
                             size: block.fontSize, context: context, pageHeight: height)
                    }
                case .system(let system):
                    drawSystem(system, plan: plan, context: context)
                }
            }
            draw("RoughScore sparse annotations - page \(page.number) / \(plan.pages.count)", x: margin,
                 top: height - margin + 2, size: 8, context: context, pageHeight: height)
            context.endPDFPage()
            guard output.length <= 67_108_864 else { context.closePDF(); throw ScoreExportError.limitExceeded }
        }
        context.closePDF()
        guard output.length > 0, output.length <= 67_108_864 else { throw ScoreExportError.limitExceeded }
        return output as Data
    }

    /// Writes atomically only after complete successful rendering. The caller owns
    /// the chosen destination; no discovery or overwrite of audio/project inputs.
    public static func write(_ plan: ScoreRenderPlan, to url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { throw ScoreExportError.invalidSettings }
        try data(for: plan).write(to: url, options: .atomic)
    }

    private static func drawSystem(_ system: ScoreRenderPlan.System, plan: ScoreRenderPlan, context: CGContext) {
        let margin = plan.settings.margin, width = plan.settings.paper.width - margin * 2
        let height = plan.settings.paper.height
        draw("Guitar \(system.lane == .left ? "L" : "R") - separate annotation columns", x: margin, top: system.top,
             size: 10, context: context, pageHeight: height)
        let gridLeft = margin + 34, columnWidth = (width - 34) / Double(system.eventIndices.count)
        for (column, index) in system.eventIndices.enumerated() {
            let e = plan.events[index], center = gridLeft + columnWidth * (Double(column) + 0.5)
            centered("#\(index + 1)", center: center, top: system.top + 15, size: 8, context: context, pageHeight: height)
            centered(String(format: "%.3f s", e.time), center: center, top: system.top + 26, size: 8, context: context, pageHeight: height)
        }
        for string in 1...6 {
            let top = system.top + 47 + Double(string - 1) * 14
            draw("s\(string)", x: margin, top: top - 6, size: 8, context: context, pageHeight: height)
            context.setStrokeColor(CGColor(gray: 0.72, alpha: 1)); context.setLineWidth(0.55)
            context.move(to: CGPoint(x: gridLeft, y: height - top)); context.addLine(to: CGPoint(x: margin + width, y: height - top)); context.strokePath()
        }
        for (column, index) in system.eventIndices.enumerated() {
            let e = plan.events[index], center = gridLeft + columnWidth * (Double(column) + 0.5)
            let top = system.top + 47 + Double(e.string - 1) * 14
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: center - 17, y: height - top - 9, width: 34, height: 18))
            context.setFillColor(CGColor(gray: 0.13, alpha: 1))
            centered("\(e.tentative ? "~" : "")\(e.fret.map(String.init) ?? "?")", center: center, top: top - 9, size: 13,
                     context: context, pageHeight: height)
        }
    }

    private static func font(_ size: Double) -> CTFont {
        CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, size, nil)
    }
    private static func line(_ text: String, size: Double) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font(size),
                                                        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
    private static func draw(_ text: String, x: Double, top: Double, size: Double, context: CGContext, pageHeight: Double) {
        context.saveGState()
        context.textMatrix = .identity; context.textPosition = CGPoint(x: x, y: pageHeight - top - size)
        CTLineDraw(line(text, size: size), context)
        context.restoreGState()
    }
    private static func centered(_ text: String, center: Double, top: Double, size: Double, context: CGContext, pageHeight: Double) {
        let value = line(text, size: size)
        let width = CTLineGetTypographicBounds(value, nil, nil, nil)
        context.saveGState()
        context.textMatrix = .identity; context.textPosition = CGPoint(x: center - width / 2, y: pageHeight - top - size)
        CTLineDraw(value, context)
        context.restoreGState()
    }

    /// Control bytes stay visible rather than disrupting tabs or disappearing from
    /// the PDF. Newline is a genuine paragraph break; backslashes remain literal.
    static func visible(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 9: "\\t"
            case 10: "\n"
            case 13: "\\r"
            case 0..<32, 127: String(format: "\\u{%04X}", scalar.value)
            default: String(scalar)
            }
        }.joined()
    }

    /// Font-measured wrapping shared by planning/rendering; never truncates text.
    static func wrappedLines(_ text: String, width: Double, size: Double) throws -> [String] {
        guard width.isFinite, width > 0, size.isFinite, size > 0 else { throw ScoreExportError.invalidSettings }
        var result = [String]()
        for paragraph in text.components(separatedBy: "\n") {
            if paragraph.isEmpty { result.append(""); continue }
            let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font(size)]
            let attributed = NSAttributedString(string: paragraph, attributes: attributes)
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let source = paragraph as NSString
            var offset = 0
            while offset < source.length {
                let count = CTTypesetterSuggestLineBreak(typesetter, offset, width)
                guard count > 0 else { throw ScoreExportError.renderingFailed }
                result.append(source.substring(with: NSRange(location: offset, length: count)))
                offset += count
            }
        }
        return result
    }
}
