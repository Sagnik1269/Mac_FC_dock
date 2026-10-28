import Foundation

enum ConversionError: LocalizedError {
    case unsupported(String)
    case unreadable(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name): return "Can't convert \(name)"
        case .unreadable(let name): return "Couldn't read \(name)"
        case .exportFailed(let reason): return "Export failed: \(reason)"
        }
    }
}

/// Something that can turn some formats into others, either built into macOS or backed by a `Tool`.
protocol Engine {
    var name: String { get }
    /// What has to be installed for this engine to work; nil when it's built into macOS.
    var tool: Tool? { get }
    /// How good this engine is at the conversion (lower is better), or nil if it can't do it directly.
    func rank(_ from: FileFormat, _ to: FileFormat) -> Int?
    /// Writes `output`, which may be a folder for conversions that produce several files (e.g. slide images).
    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws
}

extension Engine {
    var tool: Tool? { nil }
    var isAvailable: Bool { tool?.isInstalled ?? true }
}

/// Picks the best way to make each conversion, chaining two engines when no single one can,
/// and falls back to the next route if one fails.
enum Converter {
    /// Set to false to skip the iWork apps (used by the `--convert … --builtin` dev hook).
    static var useIWork = true

    /// In rough order of preference when engines rank a conversion the same.
    static let engines: [Engine] = [
        IWorkEngine.pages, IWorkEngine.numbers, IWorkEngine.keynote,
        TextSystemEngine(), ImageIOEngine(), AfconvertEngine(), MIDIEngine(),
        DataEngine(), SubtitleEngine(), ArchiveEngine(), SQLiteEngine(),
        LibreOfficeEngine(), PandocEngine(), FFmpegEngine(), ImageMagickEngine(),
        PopplerEngine(), DuckDBEngine(), TectonicEngine(),
    ]

    struct Step {
        let engine: Engine
        let from: FileFormat
        let to: FileFormat
    }

    /// Formats the wheel should offer: those every selected file can become, in the catalog's order.
    static func targets(for files: [URL]) -> [FileFormat] {
        let sources = files.compactMap(FileFormat.detect)
        guard let first = sources.first, sources.count == files.count else { return [] }
        let available = availableEngines()
        let distinct = Array(Set(sources))
        return Catalog.targets(for: first).filter { target in
            distinct.allSatisfy { source in
                source == target || !routes(from: source, to: target, using: available).isEmpty
            }
        }
    }

    /// What the wheel would offer for a file of this format.
    static func targets(from source: FileFormat) -> [FileFormat] {
        let available = availableEngines()
        return Catalog.targets(for: source).filter { !routes(from: source, to: $0, using: available).isEmpty }
    }

    /// Every way to make `to` from `from`, best first. One or two steps.
    static func routes(from: FileFormat, to: FileFormat, using engines: [Engine]? = nil) -> [[Step]] {
        let engines = engines ?? availableEngines()
        func direct(_ a: FileFormat, _ b: FileFormat) -> [(Int, Step)] {
            engines.compactMap { engine in
                engine.rank(a, b).map { ($0, Step(engine: engine, from: a, to: b)) }
            }
        }

        var routes: [(cost: Int, steps: [Step])] = direct(from, to).map { ($0.0, [$0.1]) }
        // Two steps cost extra, so a direct conversion of similar quality wins.
        for middle in FileFormat.all where middle != from && middle != to {
            let first = direct(from, middle)
            guard let best = first.min(by: { $0.0 < $1.0 }) else { continue }
            for second in direct(middle, to) {
                routes.append((best.0 + second.0 + 10, [best.1, second.1]))
            }
        }
        // A stable sort keeps the engine-list order for equal costs.
        return routes.enumerated()
            .sorted { ($0.element.cost, $0.offset) < ($1.element.cost, $1.offset) }
            .map(\.element.steps)
    }

    static func availableEngines() -> [Engine] {
        engines.filter { $0.isAvailable && (useIWork || !($0 is IWorkEngine)) }
    }

    /// Converts `source` to `format` and saves it next to the original. Returns the new file (or folder).
    static func convert(_ source: URL, to format: FileFormat) async throws -> URL {
        guard let from = FileFormat.detect(source) else {
            throw ConversionError.unsupported(source.lastPathComponent)
        }
        let routes = routes(from: from, to: format)
        guard !routes.isEmpty else { throw ConversionError.unsupported(source.lastPathComponent) }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("FCDock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        var firstError: Error?
        // Only try a few routes so a broken tool doesn't keep the user waiting.
        for (attempt, route) in routes.prefix(3).enumerated() {
            do {
                let result = try await run(route, on: source, in: workspace.appendingPathComponent("\(attempt)"))
                return try moveIntoPlace(result, nextTo: source, format: format)
            } catch {
                NSLog("FC Dock: \(route.map { "\($0.engine.name) \($0.from)→\($0.to)" }.joined(separator: ", ")) failed: \(error)")
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? ConversionError.unsupported(source.lastPathComponent)
    }

    private static func run(_ route: [Step], on source: URL, in folder: URL) async throws -> URL {
        // Intermediate files keep the original name, since some tools use it as the document title.
        let base = FileFormat.baseName(of: source)
        var input = source
        for (index, step) in route.enumerated() {
            let stepFolder = folder.appendingPathComponent("\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: stepFolder, withIntermediateDirectories: true)
            let output = stepFolder.appendingPathComponent(base).appendingPathExtension(step.to.fileExtension)
            try await step.engine.convert(input, from: step.from, to: step.to, output: output)
            guard FileManager.default.fileExists(atPath: output.path) else {
                throw ConversionError.exportFailed("\(step.engine.name) didn't write a file")
            }
            input = output
        }
        return input
    }

    private static func moveIntoPlace(_ result: URL, nextTo source: URL, format: FileFormat) throws -> URL {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: result.path, isDirectory: &isFolder)
        let destination = uniqueURL(nextTo: source, format: format, folder: isFolder.boolValue)
        try FileManager.default.moveItem(at: result, to: destination)
        return destination
    }

    /// "Report_pdf.pdf", or "Report_pdf_2.pdf" if that's taken. Folders (e.g. slide images) get no extension.
    static func uniqueURL(nextTo source: URL, format: FileFormat, folder: Bool = false) -> URL {
        let directory = source.deletingLastPathComponent()
        let base = "\(FileFormat.baseName(of: source))_\(format.suffix)"
        func candidate(_ name: String) -> URL {
            folder ? directory.appendingPathComponent(name, isDirectory: true)
                : directory.appendingPathComponent("\(name).\(format.fileExtension)")
        }
        var url = candidate(base)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = candidate("\(base)_\(counter)")
            counter += 1
        }
        return url
    }
}
