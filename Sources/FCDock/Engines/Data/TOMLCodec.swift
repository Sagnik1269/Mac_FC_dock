import Foundation

/// TOML 1.0. Dates and times are kept as text, since the other formats have no date type.
enum TOMLCodec {
    static func decode(_ text: String) throws -> Value {
        var parser = TOMLParser(text)
        return try parser.document()
    }

    /// TOML needs a table at the top and has no null, so lists get wrapped and nulls are left out.
    static func encode(_ value: Value) -> String {
        let root: [(String, Value)]
        switch value {
        case .object(let pairs): root = pairs
        default: root = [("items", value)]
        }
        var lines: [String] = []
        emitTable(root, path: [], into: &lines)
        while lines.first == "" { lines.removeFirst() }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Writing

    private static func isTableArray(_ value: Value) -> Bool {
        if case .array(let items) = value, !items.isEmpty {
            return items.allSatisfy { if case .object = $0 { return true } else { return false } }
        }
        return false
    }

    private static func emitTable(_ pairs: [(String, Value)], path: [String], into lines: inout [String]) {
        // Plain keys must come before any sub-table header.
        for (key, value) in pairs {
            if case .null = value { continue }
            if case .object = value { continue }
            if isTableArray(value) { continue }
            lines.append("\(formatKey(key)) = \(inline(value))")
        }
        for (key, value) in pairs {
            let childPath = path + [key]
            let header = childPath.map(formatKey).joined(separator: ".")
            if case .object(let children) = value {
                let hasPlainKeys = children.contains { child in
                    switch child.1 {
                    case .object, .null: return false
                    default: return !isTableArray(child.1)
                    }
                }
                // Tables that only hold other tables are implied by their children's headers.
                if hasPlainKeys || children.isEmpty {
                    lines.append("")
                    lines.append("[\(header)]")
                }
                emitTable(children, path: childPath, into: &lines)
            } else if isTableArray(value), case .array(let items) = value {
                for case .object(let children) in items {
                    lines.append("")
                    lines.append("[[\(header)]]")
                    emitTable(children, path: childPath, into: &lines)
                }
            }
        }
    }

    private static func inline(_ value: Value) -> String {
        switch value {
        case .null: return "\"\""
        case .bool(let bool): return bool ? "true" : "false"
        case .int(let int): return String(int)
        case .double(let double): return Value.format(double)
        case .string(let text): return JSONCodec.quote(text)
        case .array(let items): return "[" + items.filter { $0 != .null }.map(inline).joined(separator: ", ") + "]"
        case .object(let pairs):
            let body = pairs.filter { $0.1 != .null }.map { "\(formatKey($0.0)) = \(inline($0.1))" }.joined(separator: ", ")
            return body.isEmpty ? "{}" : "{ \(body) }"
        }
    }

    private static func formatKey(_ key: String) -> String {
        let bare = !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return bare ? key : JSONCodec.quote(key)
    }
}

// MARK: - Reading

/// Builds tables by reference while parsing, since TOML can reopen a table from anywhere in the file.
private final class TOMLTable {
    enum Entry {
        case value(Value)
        case table(TOMLTable)
        case tables([TOMLTable])
    }

    var entries: [(String, Entry)] = []
    /// Set for [headers] and dotted-key tables; inline tables are sealed.
    var isDefined = false

    func entry(_ key: String) -> Entry? { entries.first { $0.0 == key }?.1 }

    func set(_ key: String, _ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.0 == key }) { entries[index].1 = entry } else { entries.append((key, entry)) }
    }

    /// The child table at `key`, created if missing; for an array of tables, its last element.
    func child(_ key: String) throws -> TOMLTable {
        switch entry(key) {
        case .table(let table): return table
        case .tables(let tables): return tables.last!
        case .value: throw DataFormatError("Invalid TOML: \(key) is already a value")
        case nil:
            let table = TOMLTable()
            set(key, .table(table))
            return table
        }
    }

    var value: Value {
        .object(entries.map { key, entry in
            switch entry {
            case .value(let value): return (key, value)
            case .table(let table): return (key, table.value)
            case .tables(let tables): return (key, .array(tables.map(\.value)))
            }
        })
    }
}

private struct TOMLParser {
    let chars: [Character]
    var index = 0
    var line = 1

    init(_ text: String) { chars = Array(text) }

    func error(_ message: String) -> DataFormatError {
        DataFormatError("Invalid TOML on line \(line): \(message)")
    }

    var current: Character? { index < chars.count ? chars[index] : nil }

    mutating func advance() {
        if current == "\n" { line += 1 }
        index += 1
    }

    mutating func skipSpaces() {
        while let char = current, char == " " || char == "\t" { advance() }
    }

    /// Spaces, newlines and comments.
    mutating func skipAll() {
        while let char = current {
            if char.isWhitespace { advance() } else if char == "#" { skipComment() } else { break }
        }
    }

    mutating func skipComment() {
        while let char = current, char != "\n" { advance() }
    }

    mutating func endOfLine() throws {
        skipSpaces()
        if current == "#" { skipComment() }
        guard current == nil || current == "\n" || current == "\r\n" || current == "\r" else {
            throw error("expected the end of the line")
        }
    }

    mutating func document() throws -> Value {
        let root = TOMLTable()
        var table = root
        while true {
            skipAll()
            guard let char = current else { break }
            if char == "[" {
                advance()
                let isArray = current == "["
                if isArray { advance() }
                let path = try keyPath()
                guard current == "]" else { throw error("expected ]") }
                advance()
                if isArray {
                    guard current == "]" else { throw error("expected ]]") }
                    advance()
                }
                try endOfLine()
                table = try open(path, in: root, asArray: isArray)
            } else {
                let path = try keyPath()
                guard current == "=" else { throw error("expected = after the key") }
                advance()
                skipSpaces()
                let value = try self.value()
                try assign(value, to: path, in: table)
                try endOfLine()
            }
        }
        return root.value
    }

    mutating func open(_ path: [String], in root: TOMLTable, asArray: Bool) throws -> TOMLTable {
        var table = root
        for key in path.dropLast() { table = try table.child(key) }
        let last = path.last!
        if asArray {
            let element = TOMLTable()
            element.isDefined = true
            if case .tables(let existing) = table.entry(last) {
                table.set(last, .tables(existing + [element]))
            } else if table.entry(last) == nil {
                table.set(last, .tables([element]))
            } else {
                throw error("\(last) is already defined")
            }
            return element
        }
        let child = try table.child(last)
        child.isDefined = true
        return child
    }

    mutating func assign(_ value: Value, to path: [String], in table: TOMLTable) throws {
        var target = table
        for key in path.dropLast() { target = try target.child(key) }
        target.set(path.last!, .value(value))
    }

    /// `a.b."c d"` in a header or before =.
    mutating func keyPath() throws -> [String] {
        var keys: [String] = []
        while true {
            skipSpaces()
            guard let char = current else { throw error("expected a key") }
            if char == "\"" {
                keys.append(try basicString())
            } else if char == "'" {
                keys.append(try literalString())
            } else {
                let start = index
                while let next = current, next.isLetter || next.isNumber || next == "_" || next == "-" { advance() }
                guard index > start else { throw error("expected a key") }
                keys.append(String(chars[start..<index]))
            }
            skipSpaces()
            if current == "." { advance(); continue }
            return keys
        }
    }

    mutating func value() throws -> Value {
        guard let char = current else { throw error("expected a value") }
        switch char {
        case "\"":
            if starts(with: "\"\"\"") { return .string(try multilineString(literal: false)) }
            return .string(try basicString())
        case "'":
            if starts(with: "'''") { return .string(try multilineString(literal: true)) }
            return .string(try literalString())
        case "[": return try array()
        case "{": return try inlineTable()
        case "t" where starts(with: "true"): index += 4; return .bool(true)
        case "f" where starts(with: "false"): index += 5; return .bool(false)
        default: return try numberOrDate()
        }
    }

    func starts(with text: String) -> Bool {
        let needle = Array(text)
        return index + needle.count <= chars.count && Array(chars[index..<index + needle.count]) == needle
    }

    mutating func basicString() throws -> String {
        advance()
        var result = ""
        while let char = current {
            advance()
            if char == "\"" { return result }
            if char == "\n" { throw error("newline in a string") }
            if char == "\\" { result += try escape() } else { result.append(char) }
        }
        throw error("unclosed string")
    }

    mutating func literalString() throws -> String {
        advance()
        var result = ""
        while let char = current {
            advance()
            if char == "'" { return result }
            if char == "\n" { throw error("newline in a string") }
            result.append(char)
        }
        throw error("unclosed string")
    }

    mutating func multilineString(literal: Bool) throws -> String {
        let delimiter: Character = literal ? "'" : "\""
        index += 3
        // A newline straight after the opening quotes isn't part of the string.
        if current == "\n" || current == "\r\n" { advance() }
        var result = ""
        while let char = current {
            if char == delimiter, starts(with: String(repeating: delimiter, count: 3)) {
                index += 3
                // Up to two more quotes right before the closing ones belong to the string.
                while current == delimiter { result.append(delimiter); index += 1 }
                return result
            }
            advance()
            if !literal, char == "\\" {
                // A backslash at the end of a line joins it to the next, dropping the whitespace between.
                if let next = current, next.isWhitespace {
                    var lookahead = index
                    while lookahead < chars.count, chars[lookahead] == " " || chars[lookahead] == "\t" { lookahead += 1 }
                    if lookahead < chars.count, chars[lookahead].isNewline {
                        while let space = current, space.isWhitespace { advance() }
                        continue
                    }
                }
                result += try escape()
            } else {
                result.append(char)
            }
        }
        throw error("unclosed multi-line string")
    }

    mutating func escape() throws -> String {
        guard let char = current else { throw error("unfinished escape") }
        advance()
        switch char {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "b": return "\u{8}"
        case "f": return "\u{C}"
        case "e": return "\u{1B}"
        case "\"": return "\""
        case "\\": return "\\"
        case "u", "U":
            let length = char == "u" ? 4 : 8
            guard index + length <= chars.count,
                  let code = UInt32(String(chars[index..<index + length]), radix: 16),
                  let scalar = Unicode.Scalar(code) else { throw error("bad unicode escape") }
            index += length
            return String(Character(scalar))
        default: throw error("unknown escape \\\(char)")
        }
    }

    mutating func array() throws -> Value {
        advance()
        var items: [Value] = []
        while true {
            skipAll()
            guard let char = current else { throw error("unclosed array") }
            if char == "]" { advance(); return .array(items) }
            items.append(try value())
            skipAll()
            if current == "," { advance() } else if current != "]" { throw error("expected , or ] in the array") }
        }
    }

    mutating func inlineTable() throws -> Value {
        advance()
        let table = TOMLTable()
        skipSpaces()
        if current == "}" { advance(); return table.value }
        while true {
            let path = try keyPath()
            guard current == "=" else { throw error("expected = in the inline table") }
            advance()
            skipSpaces()
            try assign(try value(), to: path, in: table)
            skipSpaces()
            if current == "," { advance(); skipSpaces(); continue }
            if current == "}" { advance(); return table.value }
            throw error("expected , or } in the inline table")
        }
    }

    mutating func numberOrDate() throws -> Value {
        let start = index
        while let char = current, !char.isWhitespace, char != ",", char != "]", char != "}", char != "#" { advance() }
        // A date-time may have a space between the date and the time.
        if current == " ", index - start == 10, index + 1 < chars.count, chars[index + 1].isNumber,
           String(chars[start..<index]).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            advance()
            while let char = current, !char.isWhitespace, char != ",", char != "]", char != "}", char != "#" { advance() }
        }
        let token = String(chars[start..<index])
        let digits = token.replacingOccurrences(of: "_", with: "")

        switch digits {
        case "inf", "+inf": return .double(.infinity)
        case "-inf": return .double(-.infinity)
        case "nan", "+nan", "-nan": return .double(.nan)
        default: break
        }
        if digits.hasPrefix("0x"), let int = Int64(digits.dropFirst(2), radix: 16) { return .int(int) }
        if digits.hasPrefix("0o"), let int = Int64(digits.dropFirst(2), radix: 8) { return .int(int) }
        if digits.hasPrefix("0b"), let int = Int64(digits.dropFirst(2), radix: 2) { return .int(int) }
        if let int = Int64(digits) { return .int(int) }
        if digits.range(of: #"^[-+]?\d+(\.\d+)?([eE][-+]?\d+)?$"#, options: .regularExpression) != nil, let double = Double(digits) {
            return .double(double)
        }
        // Offset date-times, local dates and times.
        if token.range(of: #"^\d{4}-\d{2}-\d{2}|^\d{2}:\d{2}"#, options: .regularExpression) != nil {
            return .string(token)
        }
        throw error(token.isEmpty ? "expected a value" : "unexpected '\(token)'")
    }
}
