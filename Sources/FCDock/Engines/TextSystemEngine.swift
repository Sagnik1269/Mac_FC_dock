import AppKit
import PDFKit

/// Rich-text documents through the Cocoa text system (the same one TextEdit uses), plus a simple PDF
/// renderer and PDF text extraction. Built in and fast, but it loses tables and complex layout.
struct TextSystemEngine: Engine {
    let name = "Text system"

    private static let types: [FileFormat: NSAttributedString.DocumentType] = [
        .docx: .officeOpenXML, .doc: .docFormat, .odt: .openDocument, .rtf: .rtf, .html: .html, .txt: .plain,
    ]

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        guard Self.types[from] != nil || from == .pdf else { return nil }
        if to == .pdf { return from == .pdf ? nil : 30 }
        guard Self.types[to] != nil else { return nil }
        // Text pulled out of a PDF loses tables and layout, so any other route is better.
        if from == .pdf { return 20 }
        // Plain text and HTML come out well; Office formats lose layout, so prefer LibreOffice for those.
        return to == .txt || to == .html || to == .rtf ? 10 : 20
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        try await MainActor.run {
            let text = try Self.load(input, as: from)
            if to == .pdf {
                try PDFRenderer.render(text, to: output)
            } else {
                try Self.write(text, as: to, to: output)
            }
        }
    }

    // The HTML importer uses WebKit, so reading has to happen on the main thread.
    @MainActor
    static func load(_ url: URL, as format: FileFormat) throws -> NSAttributedString {
        if format == .pdf {
            guard let pdf = PDFDocument(url: url) else {
                throw ConversionError.unreadable(url.lastPathComponent)
            }
            let result = NSMutableAttributedString()
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index)?.attributedString else { continue }
                if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
                result.append(page)
            }
            return result
        }

        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: types[format]!]
        if format == .txt {
            options[.characterEncoding] = String.Encoding.utf8.rawValue
        }
        if let text = try? NSAttributedString(url: url, options: options, documentAttributes: nil) {
            return text
        }
        // Not UTF-8 (or a mislabelled file): let the text system sniff it.
        if let text = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            return text
        }
        throw ConversionError.unreadable(url.lastPathComponent)
    }

    static func write(_ text: NSAttributedString, as format: FileFormat, to url: URL) throws {
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: types[format]!]
        if format == .txt || format == .html {
            attributes[.characterEncoding] = String.Encoding.utf8.rawValue
        }
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
        try data.write(to: url, options: .withoutOverwriting)
    }
}

/// Lays out attributed text on pages and saves it as a PDF, without any UI.
enum PDFRenderer {
    @MainActor
    static func render(_ text: NSAttributedString, to url: URL) throws {
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.topMargin = 72
        printInfo.bottomMargin = 72
        printInfo.leftMargin = 72
        printInfo.rightMargin = 72
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        // Print in light mode so text without an explicit colour comes out black.
        textView.appearance = NSAppearance(named: .aqua)
        textView.drawsBackground = false
        textView.textStorage?.setAttributedString(text)

        if let layout = textView.layoutManager, let container = textView.textContainer {
            layout.ensureLayout(for: container)
            let height = layout.usedRect(for: container).height
            textView.frame.size.height = max(height, 1)
        }

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.exportFailed("couldn't render PDF")
        }
    }
}
