import Foundation

/// Office documents, spreadsheets and slides through LibreOffice in headless mode.
struct LibreOfficeEngine: Engine {
    let name = "LibreOffice"
    var tool: Tool? { .libreOffice }

    private static let families: [(inputs: Set<FileFormat>, outputs: [FileFormat: String])] = [
        // Writer
        ([.doc, .docx, .docm, .odt, .rtf, .txt, .html, .wps, .wpd, .pages], [
            .pdf: "pdf", .docx: "docx", .doc: "doc:MS Word 97", .odt: "odt", .rtf: "rtf",
            .txt: "txt:Text (encoded):UTF8", .html: "html", .epub: "epub",
        ]),
        // Calc
        ([.xls, .xlsx, .xlsm, .xlsb, .ods, .csv, .numbers, .dbf], [
            .pdf: "pdf", .xlsx: "xlsx", .xls: "xls:MS Excel 97", .ods: "ods", .html: "html",
            .csv: "csv:Text - txt - csv (StarCalc):44,34,76,1",
        ]),
        // Impress
        ([.ppt, .pptx, .pptm, .pps, .odp, .key, .fodp, .pot], [
            .pdf: "pdf", .pptx: "pptx", .ppt: "ppt:MS PowerPoint 97", .odp: "odp", .png: "png", .jpg: "jpg", .svg: "svg",
        ]),
    ]

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        guard from != to, Self.filter(from, to) != nil else { return nil }
        return to == .pdf ? 10 : 15
    }

    private static func filter(_ from: FileFormat, _ to: FileFormat) -> String? {
        families.first { $0.inputs.contains(from) }?.outputs[to]
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        guard let filter = Self.filter(from, to) else { throw ConversionError.unsupported(input.lastPathComponent) }
        let folder = output.deletingLastPathComponent().appendingPathComponent("libreoffice", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // A profile of our own, so this works even while the user has LibreOffice open.
        let profile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.sagnikmondal.fcdock/LibreOffice", isDirectory: true)
        try await ProcessRunner.run(Tool.libreOffice.path, [
            "-env:UserInstallation=\(profile.absoluteString)",
            "--headless", "--norestore", "--convert-to", filter, "--outdir", folder.path, input.path,
        ], timeout: 300)

        // LibreOffice names the file after the input; there's only one in the folder.
        guard let produced = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first else {
            throw ConversionError.exportFailed("LibreOffice didn't write a file")
        }
        try FileManager.default.moveItem(at: produced, to: output)
    }
}

/// Markdown, EPUB and LaTeX, plus cleaner HTML, through pandoc.
struct PandocEngine: Engine {
    let name = "pandoc"
    var tool: Tool? { .pandoc }

    private static let readers: [FileFormat: String] = [
        .md: "markdown", .html: "html", .docx: "docx", .odt: "odt", .txt: "markdown", .tex: "latex", .epub: "epub", .rtf: "rtf",
    ]
    private static let writers: [FileFormat: String] = [
        .md: "gfm", .html: "html", .docx: "docx", .odt: "odt", .rtf: "rtf", .epub: "epub", .txt: "plain", .tex: "latex",
    ]

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        guard from != to, Self.readers[from] != nil, Self.writers[to] != nil else { return nil }
        // pandoc is the expert for these; for plain office round-trips the text system or LibreOffice keep more styling.
        let specialty: Set<FileFormat> = [.md, .tex, .epub]
        return specialty.contains(from) || specialty.contains(to) ? 8 : 25
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        var arguments = [input.path, "-f", Self.readers[from]!, "-t", Self.writers[to]!, "-o", output.path, "--standalone"]
        if to == .html || to == .epub {
            // Without a title pandoc warns and HTML gets an empty <title>.
            arguments += ["--metadata", "pagetitle=\(FileFormat.baseName(of: input))"]
        }
        try await ProcessRunner.run(Tool.pandoc.path, arguments, in: input.deletingLastPathComponent())
    }
}

/// Image formats macOS can't write (WebP, JPEG XL, Radiance HDR), and a fallback for the rest.
struct ImageMagickEngine: Engine {
    let name = "ImageMagick"
    var tool: Tool? { .imageMagick }

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        guard from != to, from.isImage, to.isImage, to != .apng, to != .raw, to != .svg else { return nil }
        return [.webp, .jxl, .hdr].contains(to) ? 10 : 30
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        // Keep every frame when going animated → animated; otherwise just the first.
        let animated = [.gif, .apng].contains(from) && [.gif, .webp].contains(to)
        let prefix = from == .apng ? "apng:" : ""
        let source = prefix + input.path + (animated ? "" : "[0]")
        var arguments = [source]
        if to == .webp { arguments += ["-quality", "90"] }
        try await ProcessRunner.run(Tool.imageMagick.path, arguments + [output.path])
    }
}

/// PDF → SVG through Poppler's pdftocairo (first page).
struct PopplerEngine: Engine {
    let name = "Poppler"
    var tool: Tool? { .poppler }

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        from == .pdf && to == .svg ? 10 : nil
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        try await ProcessRunner.run(Tool.poppler.path, ["-svg", "-f", "1", "-l", "1", input.path, output.path])
    }
}

/// LaTeX → PDF through Tectonic, which fetches the packages a document needs on first use.
struct TectonicEngine: Engine {
    let name = "Tectonic"
    var tool: Tool? { .tectonic }

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        from == .tex && to == .pdf ? 5 : nil
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        let folder = output.deletingLastPathComponent()
        // Run beside the source so \input and \includegraphics paths resolve.
        try await ProcessRunner.run(Tool.tectonic.path, ["--outdir", folder.path, input.path],
                                    in: input.deletingLastPathComponent(), timeout: 600)
        let produced = folder.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".pdf")
        if produced != output { try FileManager.default.moveItem(at: produced, to: output) }
    }
}

/// Parquet ⇄ CSV/TSV/JSON/NDJSON through DuckDB.
struct DuckDBEngine: Engine {
    let name = "DuckDB"
    var tool: Tool? { .duckdb }

    private static let readers: [FileFormat: String] = [
        .parquet: "read_parquet(%@)",
        .csv: "read_csv_auto(%@)",
        .tsv: "read_csv(%@, delim='\\t', header=true, auto_detect=true)",
        .json: "read_json_auto(%@)",
        .ndjson: "read_json_auto(%@, format='newline_delimited')",
    ]
    private static let writers: [FileFormat: String] = [
        .parquet: "FORMAT parquet",
        .csv: "FORMAT csv, HEADER true",
        .tsv: "FORMAT csv, HEADER true, DELIMITER '\\t'",
        .json: "FORMAT json, ARRAY true",
        .ndjson: "FORMAT json",
    ]

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        guard from != to, Self.readers[from] != nil, Self.writers[to] != nil else { return nil }
        // Only needed when Parquet is involved; the built-in data engine handles the rest.
        return from == .parquet || to == .parquet ? 10 : nil
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        let read = String(format: Self.readers[from]!, Self.quoted(input.path))
        let sql = "COPY (SELECT * FROM \(read)) TO \(Self.quoted(output.path)) (\(Self.writers[to]!));"
        try await ProcessRunner.run(Tool.duckdb.path, ["-c", sql])
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

/// SQLite databases ⇄ SQL dumps, and tables → CSV/JSON, with the sqlite3 that ships with macOS.
struct SQLiteEngine: Engine {
    let name = "SQLite"
    private static let sqlite = "/usr/bin/sqlite3"

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        switch (from, to) {
        case (.sqlite, .sql), (.sqlite, .csv), (.sqlite, .json), (.sql, .sqlite): return 10
        default: return nil
        }
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        switch to {
        case .sql:
            try await ProcessRunner.run(Self.sqlite, ["-readonly", input.path, ".output \(Self.quoted(output.path))", ".dump"])
        case .sqlite:
            try await ProcessRunner.run(Self.sqlite, ["-bail", output.path, ".read \(Self.quoted(input.path))"])
        case .csv:
            let tables = try await Self.tables(in: input)
            if tables.count == 1 {
                try await Self.exportCSV(input, table: tables[0], to: output)
            } else {
                // One CSV per table, in a folder.
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                for table in tables {
                    try await Self.exportCSV(input, table: table, to: output.appendingPathComponent("\(table).csv"))
                }
            }
        case .json:
            // One table → an array of rows; several → an object of table name → rows.
            var result: [(String, Value)] = []
            for table in try await Self.tables(in: input) {
                let data = try await ProcessRunner.run(Self.sqlite, ["-readonly", "-json", input.path, "SELECT * FROM \(Self.identifier(table))"])
                // An empty table prints nothing at all.
                let rows = data.isEmpty ? Value.array([]) : try JSONCodec.decode(String(decoding: data, as: UTF8.self))
                result.append((table, rows))
            }
            let value = result.count == 1 ? result[0].1 : .object(result)
            try Data((JSONCodec.encode(value) + "\n").utf8).write(to: output)
        default:
            throw ConversionError.unsupported(input.lastPathComponent)
        }
    }

    private static func tables(in database: URL) async throws -> [String] {
        let data = try await ProcessRunner.run(sqlite, [
            "-readonly", database.path,
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
        ])
        let tables = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard !tables.isEmpty else { throw ConversionError.exportFailed("the database has no tables") }
        return tables
    }

    private static func exportCSV(_ database: URL, table: String, to output: URL) async throws {
        try await ProcessRunner.run(sqlite, [
            "-readonly", "-header", "-csv", database.path,
            ".output \(quoted(output.path))", "SELECT * FROM \(identifier(table))",
        ])
    }

    private static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func identifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
