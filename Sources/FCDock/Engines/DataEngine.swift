import Foundation

/// Structured data (JSON, YAML, TOML, XML, INI, CSV/TSV, NDJSON, BSON, MessagePack), all in Swift:
/// each format reads into a `Value` tree and any other is written from it.
struct DataEngine: Engine {
    let name = "Data"

    private static let readable: Set<FileFormat> = [.json, .ndjson, .yaml, .toml, .xml, .ini, .csv, .tsv, .bson, .msgpack]
    private static let writable: Set<FileFormat> = [.json, .ndjson, .yaml, .toml, .xml, .csv, .tsv, .bson, .msgpack, .html]

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        guard from != to, Self.readable.contains(from), Self.writable.contains(to) else { return nil }
        return 10
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        let data = try Data(contentsOf: input)
        let title = FileFormat.baseName(of: input)

        // CSV/TSV ⇄ CSV/TSV/HTML keeps cells exactly as written rather than going through typed values.
        if let table = try Self.readTable(data, from: from), [.csv, .tsv, .html].contains(to) {
            try Self.write(table: table, as: to, title: title, to: output)
            return
        }

        let value = try Self.read(data, as: from)
        switch to {
        case .csv, .tsv, .html: try Self.write(table: Table(value), as: to, title: title, to: output)
        case .json: try Data((JSONCodec.encode(value) + "\n").utf8).write(to: output)
        case .ndjson: try Data(JSONCodec.encodeLines(value).utf8).write(to: output)
        case .yaml: try Data(YAMLCodec.encode(value).utf8).write(to: output)
        case .toml: try Data(TOMLCodec.encode(value).utf8).write(to: output)
        case .xml: try Data(XMLCodec.encode(value).utf8).write(to: output)
        case .bson: try BSONCodec.encode(value).write(to: output)
        case .msgpack: try MessagePackCodec.encode(value).write(to: output)
        default: throw ConversionError.unsupported(input.lastPathComponent)
        }
    }

    private static func text(_ data: Data) -> String {
        // Most data files are UTF-8; Latin-1 decodes anything else without failing.
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private static func readTable(_ data: Data, from format: FileFormat) throws -> Table? {
        switch format {
        case .csv: return CSVCodec.decode(text(data), separator: detectSeparator(text(data)))
        case .tsv: return CSVCodec.decode(text(data), separator: "\t")
        default: return nil
        }
    }

    private static func read(_ data: Data, as format: FileFormat) throws -> Value {
        switch format {
        case .json: return try JSONCodec.decode(text(data))
        case .ndjson: return try JSONCodec.decodeLines(text(data))
        case .yaml: return try YAMLCodec.decode(text(data))
        case .toml: return try TOMLCodec.decode(text(data))
        case .xml: return try XMLCodec.decode(data)
        case .ini: return INICodec.decode(text(data))
        case .bson: return try BSONCodec.decode(data)
        case .msgpack: return try MessagePackCodec.decode(data)
        case .csv, .tsv: return try readTable(data, from: format)!.value
        default: throw ConversionError.unsupported(format.label)
        }
    }

    private static func write(table: Table, as format: FileFormat, title: String, to output: URL) throws {
        let text: String
        switch format {
        case .csv: text = CSVCodec.encode(table, separator: ",")
        case .tsv: text = CSVCodec.encode(table, separator: "\t")
        default: text = HTMLTableCodec.encode(table, title: title)
        }
        try Data(text.utf8).write(to: output)
    }

    /// European CSVs often use semicolons; pick whichever separator the header line uses most.
    private static func detectSeparator(_ text: String) -> Character {
        let header = text.prefix { !$0.isNewline }
        let counts: [(Character, Int)] = [",", ";", "\t", "|"].map { separator in (separator, header.filter { $0 == separator }.count) }
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }
}
