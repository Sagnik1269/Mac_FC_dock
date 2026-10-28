import Foundation

/// Pages, Numbers and Keynote, scripted through AppleScript. They keep Office layouts far better
/// than the text system, and they're the only way to read their own formats.
struct IWorkEngine: Engine {
    let name: String
    let tool: Tool?
    private let bundleID: String
    private let inputs: Set<FileFormat>
    /// Target format → (AppleScript export clause, rank).
    private let exports: [FileFormat: (clause: String, rank: Int)]
    /// The app's own format, which only it can read, so everything from it ranks best.
    private let native: FileFormat

    static let pages = IWorkEngine(
        name: "Pages", tool: .pages, bundleID: "com.apple.iWork.Pages",
        inputs: [.docx, .doc, .rtf, .txt, .pages],
        exports: [
            .pdf: ("PDF", 5),
            .epub: ("EPUB", 10),
            .docx: ("Microsoft Word", 25),
            .rtf: ("formatted text", 25),
            .txt: ("unformatted text", 25),
        ],
        native: .pages
    )

    static let numbers = IWorkEngine(
        name: "Numbers", tool: .numbers, bundleID: "com.apple.iWork.Numbers",
        inputs: [.xlsx, .xls, .xlsm, .csv, .tsv, .numbers],
        exports: [
            .pdf: ("PDF", 5),
            .xlsx: ("Microsoft Excel", 10),
            .csv: ("CSV", 10),
        ],
        native: .numbers
    )

    static let keynote = IWorkEngine(
        name: "Keynote", tool: .keynote, bundleID: "com.apple.iWork.Keynote",
        inputs: [.pptx, .ppt, .pptm, .pps, .key],
        exports: [
            .pdf: ("PDF", 5),
            .pptx: ("Microsoft PowerPoint", 10),
            .png: ("slide images with properties {image format:PNG}", 10),
            .jpg: ("slide images with properties {image format:JPEG}", 10),
        ],
        native: .key
    )

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        guard inputs.contains(from), from != to, let export = exports[to] else { return nil }
        return from == native ? 5 : export.rank
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        guard let export = exports[to] else { throw ConversionError.unsupported(input.lastPathComponent) }
        // Slide images come out as a folder of numbered files at `output`.
        let script = """
        on run argv
            set inFile to POSIX file (item 1 of argv)
            set outFile to POSIX file (item 2 of argv)
            set wasRunning to application id "\(bundleID)" is running
            with timeout of 180 seconds
                tell application id "\(bundleID)"
                    set theDoc to open inFile
                    export theDoc to outFile as \(export.clause)
                    close theDoc saving no
                    if not wasRunning then quit
                end tell
            end timeout
        end run
        """
        // Numbers writes a folder of CSVs when the spreadsheet has several tables; that folder is kept as is.
        try await ProcessRunner.run("/usr/bin/osascript", ["-e", script, input.path, output.path])
    }
}
