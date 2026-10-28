import Foundation

struct DataFormatError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - JSON

/// JSON with key order preserved (JSONSerialization sorts or scrambles keys).
enum JSONCodec {
    static func decode(_ text: String) throws -> Value {
        var parser = Parser(text)
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.atEnd else { throw parser.error("unexpected text after the JSON value") }
        return value
    }

    /// One JSON value per line (NDJSON / JSON Lines).
    static func decodeLines(_ text: String) throws -> Value {
        .array(try text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : try decode(trimmed)
        })
    }

    static func encode(_ value: Value, pretty: Bool = true) throws -> String {
        var output = ""
        write(value, pretty: pretty, indent: 0, into: &output)
        return output
    }

    static func encodeLines(_ value: Value) throws -> String {
        let items: [Value]
        if case .array(let array) = value { items = array } else { items = [value] }
        return try items.map { try encode($0, pretty: false) }.joined(separator: "\n") + "\n"
    }

    private static func write(_ value: Value, pretty: Bool, indent: Int, into output: inout String) {
        let newline = pretty ? "\n" : ""
        let pad = pretty ? String(repeating: "  ", count: indent + 1) : ""
        let closePad = pretty ? String(repeating: "  ", count: indent) : ""
        switch value {
        case .null: output += "null"
        case .bool(let bool): output += bool ? "true" : "false"
        case .int(let int): output += String(int)
        case .double(let double): output += double.isFinite ? Value.format(double) : "null"
        case .string(let string): output += quote(string)
        case .array(let items):
            guard !items.isEmpty else { output += "[]"; return }
            output += "[" + newline
            for (index, item) in items.enumerated() {
                output += pad
                write(item, pretty: pretty, indent: indent + 1, into: &output)
                output += (index < items.count - 1 ? "," : "") + newline
            }
            output += closePad + "]"
        case .object(let pairs):
            guard !pairs.isEmpty else { output += "{}"; return }
            output += "{" + newline
            for (index, (key, item)) in pairs.enumerated() {
                output += pad + quote(key) + (pretty ? ": " : ":")
                write(item, pretty: pretty, indent: indent + 1, into: &output)
                output += (index < pairs.count - 1 ? "," : "") + newline
            }
            output += closePad + "}"
        }
    }

    static func quote(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private struct Parser {
        let chars: [Character]
        var index = 0

        init(_ text: String) { chars = Array(text) }

        var atEnd: Bool { index >= chars.count }

        func error(_ message: String) -> DataFormatError {
            let line = chars[..<min(index, chars.count)].filter { $0 == "\n" }.count + 1
            return DataFormatError("Invalid JSON on line \(line): \(message)")
        }

        mutating func skipWhitespace() {
            while index < chars.count, chars[index].isWhitespace { index += 1 }
        }

        mutating func value() throws -> Value {
            guard index < chars.count else { throw error("unexpected end") }
            switch chars[index] {
            case "{": return try object()
            case "[": return try array()
            case "\"": return .string(try string())
            case "t": try literal("true"); return .bool(true)
            case "f": try literal("false"); return .bool(false)
            case "n": try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            for expected in word {
                guard index < chars.count, chars[index] == expected else { throw error("expected \(word)") }
                index += 1
            }
        }

        mutating func object() throws -> Value {
            index += 1
            var pairs: [(String, Value)] = []
            skipWhitespace()
            if index < chars.count, chars[index] == "}" { index += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard index < chars.count, chars[index] == "\"" else { throw error("expected a key") }
                let key = try string()
                skipWhitespace()
                guard index < chars.count, chars[index] == ":" else { throw error("expected ':'") }
                index += 1
                skipWhitespace()
                pairs.append((key, try value()))
                skipWhitespace()
                guard index < chars.count else { throw error("unclosed object") }
                if chars[index] == "," { index += 1; continue }
                if chars[index] == "}" { index += 1; return .object(pairs) }
                throw error("expected ',' or '}'")
            }
        }

        mutating func array() throws -> Value {
            index += 1
            var items: [Value] = []
            skipWhitespace()
            if index < chars.count, chars[index] == "]" { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                guard index < chars.count else { throw error("unclosed array") }
                if chars[index] == "," { index += 1; continue }
                if chars[index] == "]" { index += 1; return .array(items) }
                throw error("expected ',' or ']'")
            }
        }

        mutating func string() throws -> String {
            index += 1
            var result = ""
            while index < chars.count {
                let char = chars[index]
                index += 1
                if char == "\"" { return result }
                guard char == "\\" else { result.append(char); continue }
                guard index < chars.count else { break }
                let escape = chars[index]
                index += 1
                switch escape {
                case "n": result += "\n"
                case "t": result += "\t"
                case "r": result += "\r"
                case "b": result += "\u{8}"
                case "f": result += "\u{C}"
                case "u":
                    var code = try hex4()
                    // Surrogate pairs encode characters outside the Basic Multilingual Plane.
                    if (0xD800..<0xDC00).contains(code), index + 1 < chars.count, chars[index] == "\\", chars[index + 1] == "u" {
                        index += 2
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    result.unicodeScalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: result.append(escape)
                }
            }
            throw error("unclosed string")
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= chars.count, let code = UInt32(String(chars[index..<index + 4]), radix: 16) else {
                throw error("bad \\u escape")
            }
            index += 4
            return code
        }

        mutating func number() throws -> Value {
            let start = index
            while index < chars.count, "+-0123456789.eE".contains(chars[index]) { index += 1 }
            let text = String(chars[start..<index])
            if let int = Int64(text) { return .int(int) }
            if let double = Double(text) { return .double(double) }
            throw error("unexpected '\(text.isEmpty ? String(chars[start]) : text)'")
        }
    }
}

// MARK: - CSV / TSV

enum CSVCodec {
    static func decode(_ text: String, separator: Character) -> Table {
        var records = parse(text, separator: separator)
        // Excel adds a byte-order mark to UTF-8 CSVs.
        if var first = records.first?.first, first.hasPrefix("\u{FEFF}") {
            first.removeFirst()
            records[0][0] = first
        }
        guard let header = records.first else { return Table(columns: [], rows: []) }
        let columns = header.enumerated().map { $1.isEmpty ? "column\($0 + 1)" : $1 }
        let rows = records.dropFirst().map { record in
            columns.indices.map { $0 < record.count ? Value.string(record[$0]) : .string("") }
        }
        return Table(columns: columns, rows: rows)
    }

    /// RFC 4180: quoted fields may hold separators, doubled quotes and newlines.
    private static func parse(_ text: String, separator: Character) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = iterator.next()

        while let char = pending {
            pending = iterator.next()
            if inQuotes {
                if char == "\"" {
                    if pending == "\"" { field.append("\""); pending = iterator.next() } else { inQuotes = false }
                } else {
                    field.append(char)
                }
                continue
            }
            switch char {
            case "\"" where field.isEmpty: inQuotes = true
            case separator: record.append(field); field = ""
            case "\n", "\r\n", "\r":
                record.append(field)
                field = ""
                if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
                record = []
            default: field.append(char)
            }
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }

    static func encode(_ table: Table, separator: Character) -> String {
        func cell(_ text: String) -> String {
            guard text.contains(where: { $0 == separator || $0 == "\"" || $0.isNewline }) else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let lines = [table.columns.map(cell)] + table.rows.map { $0.map { cell($0.text) } }
        return lines.map { $0.joined(separator: String(separator)) }.joined(separator: "\n") + "\n"
    }
}

// MARK: - HTML table

enum HTMLTableCodec {
    static func encode(_ table: Table, title: String) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let head = table.columns.map { "<th>\(escape($0))</th>" }.joined()
        let body = table.rows.map { row in
            "    <tr>" + row.map { "<td>\(escape($0.text))</td>" }.joined() + "</tr>"
        }.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escape(title))</title>
        <style>
          body { font: 14px -apple-system, system-ui, sans-serif; margin: 2em; }
          table { border-collapse: collapse; }
          th, td { border: 1px solid #ccc; padding: 4px 10px; text-align: left; vertical-align: top; }
          th { background: #f3f3f3; }
          tr:nth-child(even) td { background: #fafafa; }
        </style>
        </head>
        <body>
        <table>
          <thead><tr>\(head)</tr></thead>
          <tbody>
        \(body)
          </tbody>
        </table>
        </body>
        </html>

        """
    }
}

// MARK: - INI

enum INICodec {
    /// Sections become objects; keys before any section sit at the top level.
    static func decode(_ text: String) -> Value {
        var root: [(String, Value)] = []
        var section: String?
        var entries: [(String, Value)] = []

        func closeSection() {
            if let section { root.append((section, .object(entries))) } else { root += entries }
            entries = []
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                closeSection()
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let split = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else {
                entries.append((line, .bool(true)))
                continue
            }
            let key = line[..<split].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
                entries.append((key, .string(value)))
            } else {
                entries.append((key, Value.inferred(value)))
            }
        }
        closeSection()
        return .object(root)
    }
}
