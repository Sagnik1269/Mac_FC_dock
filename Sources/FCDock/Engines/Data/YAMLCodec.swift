import Foundation

/// YAML as config files and data dumps use it: block and flow collections, quoted, plain and block
/// scalars, comments, anchors/aliases and merge keys, and several documents in one file.
/// Not supported: complex (`? `) keys and explicit indentation indicators.
enum YAMLCodec {
    static func decode(_ text: String) throws -> Value {
        var parser = YAMLParser(text)
        return try parser.documents()
    }

    static func encode(_ value: Value) -> String {
        var lines: [String] = []
        switch value {
        case .object(let pairs) where !pairs.isEmpty: emitObject(pairs, indent: 0, into: &lines)
        case .array(let items) where !items.isEmpty: emitArray(items, indent: 0, into: &lines)
        default: lines.append(inline(value) ?? quoted(value.text))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Writing

    private static func pad(_ indent: Int) -> String { String(repeating: "  ", count: indent) }

    private static func emitObject(_ pairs: [(String, Value)], indent: Int, into lines: inout [String]) {
        for (key, value) in pairs {
            let prefix = pad(indent) + scalarKey(key) + ":"
            emitValue(value, prefix: prefix, indent: indent, into: &lines)
        }
    }

    private static func emitArray(_ items: [Value], indent: Int, into lines: inout [String]) {
        for item in items {
            switch item {
            case .object(let pairs) where !pairs.isEmpty:
                // "- first: 1" then the remaining keys line up under "first".
                var nested: [String] = []
                emitObject(pairs, indent: indent + 1, into: &nested)
                nested[0] = pad(indent) + "- " + nested[0].dropFirst(pad(indent + 1).count)
                lines += nested
            case .array(let inner) where !inner.isEmpty:
                var nested: [String] = []
                emitArray(inner, indent: indent + 1, into: &nested)
                nested[0] = pad(indent) + "- " + nested[0].dropFirst(pad(indent + 1).count)
                lines += nested
            default:
                emitValue(item, prefix: pad(indent) + "-", indent: indent, into: &lines)
            }
        }
    }

    /// Writes `prefix` followed by the value: inline for scalars, on the following lines for collections.
    private static func emitValue(_ value: Value, prefix: String, indent: Int, into lines: inout [String]) {
        switch value {
        case .object(let pairs) where !pairs.isEmpty:
            lines.append(prefix)
            emitObject(pairs, indent: indent + 1, into: &lines)
        case .array(let items) where !items.isEmpty:
            lines.append(prefix)
            emitArray(items, indent: indent + 1, into: &lines)
        case .string(let text) where text.contains("\n") && !text.hasPrefix(" "):
            // Multi-line text reads best as a literal block.
            let chomp = text.hasSuffix("\n\n") ? "+" : text.hasSuffix("\n") ? "" : "-"
            lines.append(prefix + " |" + chomp)
            var body = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if body.last == "" { body.removeLast() }
            lines += body.map { $0.isEmpty ? "" : pad(indent + 1) + $0 }
        default:
            lines.append(prefix + " " + (inline(value) ?? quoted(value.text)))
        }
    }

    private static func inline(_ value: Value) -> String? {
        switch value {
        case .null: return "null"
        case .bool(let bool): return bool ? "true" : "false"
        case .int(let int): return String(int)
        case .double(let double):
            if double.isNaN { return ".nan" }
            if double.isInfinite { return double > 0 ? ".inf" : "-.inf" }
            return Value.format(double)
        case .string(let text): return isPlainSafe(text) ? text : quoted(text)
        case .array: return "[]"
        case .object: return "{}"
        }
    }

    private static func scalarKey(_ key: String) -> String {
        isPlainSafe(key) ? key : quoted(key)
    }

    private static func quoted(_ text: String) -> String { JSONCodec.quote(text) }

    /// Whether text can be written without quotes and still read back as the same string.
    private static func isPlainSafe(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last, !first.isWhitespace, !last.isWhitespace else { return false }
        if "-?:,[]{}#&*!|>'\"%@`".contains(first) { return false }
        if text.contains(": ") || text.contains(" #") || text.hasSuffix(":") || text.contains(where: \.isNewline) { return false }
        if text.unicodeScalars.contains(where: { $0.value < 0x20 }) { return false }
        // Would read back as a number, boolean or null.
        if case .string = YAMLParser.resolve(text) { return true }
        return false
    }
}

// MARK: - Reading

private struct YAMLParser {
    struct Line {
        let indent: Int
        var text: String
        let number: Int
    }

    var lines: [Line]
    var index = 0
    var anchors: [String: Value] = [:]

    init(_ source: String) {
        lines = source.components(separatedBy: .newlines).enumerated().map { number, raw in
            let indent = raw.prefix { $0 == " " }.count
            let text = String(raw.dropFirst(indent))
            return Line(indent: indent, text: text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression), number: number + 1)
        }
    }

    func error(_ message: String) -> DataFormatError {
        let line = index < lines.count ? lines[index].number : lines.count
        return DataFormatError("Invalid YAML on line \(line): \(message)")
    }

    // MARK: Structure

    mutating func documents() throws -> Value {
        var documents: [Value] = []
        while true {
            // Skip blank lines, comments, directives and document markers.
            while index < lines.count {
                let content = Self.stripComment(lines[index].text)
                if content.isEmpty || content.hasPrefix("%") || content == "---" || content == "..." {
                    index += 1
                } else if content.hasPrefix("--- ") {
                    lines[index].text = String(content.dropFirst(4))
                    break
                } else {
                    break
                }
            }
            guard index < lines.count else { break }
            documents.append(try node(minIndent: lines[index].indent))
            if index < lines.count, !Self.isDocumentBoundary(lines[index].text) {
                throw error("unexpected indentation")
            }
        }
        return documents.count == 1 ? documents[0] : documents.isEmpty ? .null : .array(documents)
    }

    private static func isDocumentBoundary(_ text: String) -> Bool {
        let content = stripComment(text)
        return content == "---" || content == "..." || content.hasPrefix("--- ")
    }

    mutating func skipBlank() {
        while index < lines.count, Self.stripComment(lines[index].text).isEmpty { index += 1 }
    }

    mutating func node(minIndent: Int) throws -> Value {
        skipBlank()
        guard index < lines.count, lines[index].indent >= minIndent, !Self.isDocumentBoundary(lines[index].text) else { return .null }
        let line = lines[index]
        let content = Self.stripComment(line.text)
        if content == "-" || content.hasPrefix("- ") { return try sequence(indent: line.indent) }
        if Self.splitKey(content) != nil { return try mapping(indent: line.indent) }
        index += 1
        return try inline(content, parentIndent: line.indent - 1)
    }

    mutating func sequence(indent: Int) throws -> Value {
        var items: [Value] = []
        while true {
            skipBlank()
            guard index < lines.count, lines[index].indent == indent else { break }
            let content = Self.stripComment(lines[index].text)
            guard content == "-" || content.hasPrefix("- ") else { break }
            if content == "-" {
                index += 1
                items.append(try node(minIndent: indent + 1))
                continue
            }
            // Treat what follows "- " as a line of its own, indented to where it starts,
            // so "- name: x" opens a mapping whose later keys line up under "name".
            let rest = lines[index].text.dropFirst(1)
            let gap = rest.prefix { $0 == " " }.count
            lines[index] = Line(indent: indent + 1 + gap, text: String(rest.dropFirst(gap)), number: lines[index].number)
            items.append(try node(minIndent: indent + 1 + gap))
        }
        return .array(items)
    }

    mutating func mapping(indent: Int) throws -> Value {
        var pairs: [(String, Value)] = []
        while true {
            skipBlank()
            guard index < lines.count, lines[index].indent == indent,
                  let (key, rest) = Self.splitKey(Self.stripComment(lines[index].text)) else { break }
            index += 1
            let value = try inline(rest, parentIndent: indent)

            if key == "<<" {
                // Merge keys pull in another mapping's pairs without overriding ones set here.
                let sources: [Value]
                if case .array(let items) = value { sources = items } else { sources = [value] }
                for case .object(let merged) in sources {
                    for pair in merged where !pairs.contains(where: { $0.0 == pair.0 }) { pairs.append(pair) }
                }
                continue
            }
            if let existing = pairs.firstIndex(where: { $0.0 == key }) {
                pairs[existing].1 = value
            } else {
                pairs.append((key, value))
            }
        }
        return .object(pairs)
    }

    /// A value written after "key:" or "- ", or on a line of its own. An empty one means the value is the
    /// indented block on the following lines (or a sequence at the same indent, which YAML allows after a key).
    mutating func inline(_ text: String, parentIndent: Int) throws -> Value {
        var rest = text.trimmingCharacters(in: .whitespaces)
        var anchor: String?
        var tag: String?
        while let first = rest.first, first == "&" || first == "!" {
            let token = rest.prefix { !$0.isWhitespace }
            if first == "&" { anchor = String(token.dropFirst()) } else { tag = String(token) }
            rest = rest.dropFirst(token.count).trimmingCharacters(in: .whitespaces)
        }

        var value: Value
        if rest.isEmpty {
            skipBlank()
            if index < lines.count, lines[index].indent > parentIndent {
                value = try node(minIndent: parentIndent + 1)
            } else if index < lines.count, lines[index].indent == parentIndent,
                      Self.stripComment(lines[index].text) == "-" || Self.stripComment(lines[index].text).hasPrefix("- ") {
                value = try sequence(indent: parentIndent)
            } else {
                value = .null
            }
        } else if rest.hasPrefix("*") {
            let name = String(rest.dropFirst())
            guard let aliased = anchors[name] else { throw error("unknown alias *\(name)") }
            value = aliased
        } else if rest.hasPrefix("|") || rest.hasPrefix(">") {
            value = .string(blockScalar(header: rest, parentIndent: parentIndent))
        } else if rest.hasPrefix("[") || rest.hasPrefix("{") {
            value = try flow(startingWith: rest)
        } else if rest.hasPrefix("\"") || rest.hasPrefix("'") {
            value = .string(try quotedScalar(startingWith: rest))
        } else {
            value = tag == "!!str" ? .string(rest) : Self.resolve(rest)
        }

        if tag == "!!str", value.isScalar { value = .string(value.text) }
        if let anchor { anchors[anchor] = value }
        return value
    }

    // MARK: Scalars

    mutating func blockScalar(header: String, parentIndent: Int) -> String {
        let folded = header.hasPrefix(">")
        let chomp: Character? = header.contains("-") ? "-" : header.contains("+") ? "+" : nil

        var body: [String] = []
        var blockIndent: Int?
        while index < lines.count {
            let line = lines[index]
            if line.text.isEmpty {
                body.append("")
                index += 1
                continue
            }
            guard line.indent > parentIndent else { break }
            let base = blockIndent ?? line.indent
            blockIndent = base
            guard line.indent >= base else { break }
            body.append(String(repeating: " ", count: line.indent - base) + line.text)
            index += 1
        }

        // Trailing blank lines belong to chomping, not to the text.
        var trailing = 0
        while body.last == "" { body.removeLast(); trailing += 1 }

        var text: String
        if folded {
            text = ""
            var previousBlank = true
            for line in body {
                if line.isEmpty {
                    text += "\n"
                    previousBlank = true
                } else if line.hasPrefix(" ") {
                    // More-indented lines keep their line breaks.
                    text += (previousBlank ? "" : "\n") + line
                    previousBlank = false
                } else {
                    text += (previousBlank ? "" : " ") + line
                    previousBlank = false
                }
            }
        } else {
            text = body.joined(separator: "\n")
        }

        switch chomp {
        case "-": return text
        case "+": return text + String(repeating: "\n", count: trailing + 1)
        default: return body.isEmpty ? "" : text + "\n"
        }
    }

    /// A quoted scalar, which may continue onto the following lines.
    mutating func quotedScalar(startingWith first: String) throws -> String {
        var text = first
        let quote = first.first!
        while Self.closingQuote(in: text, quote: quote) == nil {
            guard index < lines.count else { throw error("unclosed quoted string") }
            text += " " + lines[index].text
            index += 1
        }
        let end = Self.closingQuote(in: text, quote: quote)!
        return Self.unquote(String(text[...end]))
    }

    static func closingQuote(in text: String, quote: Character) -> String.Index? {
        var position = text.index(after: text.startIndex)
        while position < text.endIndex {
            let char = text[position]
            if quote == "\"", char == "\\" {
                position = text.index(position, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }
            if char == quote {
                let next = text.index(after: position)
                // '' inside single quotes is an escaped quote.
                if quote == "'", next < text.endIndex, text[next] == "'" {
                    position = text.index(after: next)
                    continue
                }
                return position
            }
            position = text.index(after: position)
        }
        return nil
    }

    static func unquote(_ text: String) -> String {
        let inner = String(text.dropFirst().dropLast())
        if text.first == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        var result = ""
        var chars = inner.makeIterator()
        while let char = chars.next() {
            guard char == "\\", let escape = chars.next() else { result.append(char); continue }
            switch escape {
            case "n": result += "\n"
            case "t": result += "\t"
            case "r": result += "\r"
            case "0": result += "\0"
            case "e": result += "\u{1B}"
            case "x", "u", "U":
                let length = escape == "x" ? 2 : escape == "u" ? 4 : 8
                var hex = ""
                for _ in 0..<length { if let digit = chars.next() { hex.append(digit) } }
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { result.unicodeScalars.append(scalar) }
            default: result.append(escape)
            }
        }
        return result
    }

    /// YAML 1.2 core schema: null, booleans, integers (decimal, hex, octal) and floats; anything else is text.
    static func resolve(_ text: String) -> Value {
        switch text {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        case ".inf", ".Inf", ".INF", "+.inf": return .double(.infinity)
        case "-.inf", "-.Inf", "-.INF": return .double(-.infinity)
        case ".nan", ".NaN", ".NAN": return .double(.nan)
        default: break
        }
        if text.range(of: #"^[-+]?[0-9]+$"#, options: .regularExpression) != nil, let int = Int64(text) { return .int(int) }
        if text.hasPrefix("0x"), let int = Int64(text.dropFirst(2), radix: 16) { return .int(int) }
        if text.hasPrefix("0o"), let int = Int64(text.dropFirst(2), radix: 8) { return .int(int) }
        if text.range(of: #"^[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil,
           let double = Double(text) {
            return .double(double)
        }
        return .string(text)
    }

    // MARK: Flow collections

    /// `[a, b]` and `{a: 1}`, which may span several lines.
    mutating func flow(startingWith first: String) throws -> Value {
        var text = first
        while !Self.isBalanced(text) {
            guard index < lines.count else { throw error("unclosed \(first.first!)") }
            text += " " + Self.stripComment(lines[index].text)
            index += 1
        }
        var parser = FlowParser(chars: Array(text), anchors: anchors)
        let value = try parser.value()
        return value
    }

    static func isBalanced(_ text: String) -> Bool {
        var depth = 0
        var quote: Character?
        for char in text {
            if let open = quote {
                if char == open { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "[" || char == "{" {
                depth += 1
            } else if char == "]" || char == "}" {
                depth -= 1
            }
        }
        return depth <= 0
    }

    // MARK: Lexing helpers

    /// Removes a trailing "# comment" (one that starts the line or follows whitespace, outside quotes).
    static func stripComment(_ text: String) -> String {
        var quote: Character?
        var previous: Character = " "
        var depth = 0
        for (offset, char) in text.enumerated() {
            if let open = quote {
                if char == open { quote = nil }
            } else if (char == "\"" || char == "'") && (previous.isWhitespace || "[{,:-".contains(previous) || offset == 0) {
                quote = char
            } else if char == "#" && previous.isWhitespace {
                return String(text.prefix(offset)).trimmingCharacters(in: .whitespaces)
            } else if char == "[" || char == "{" {
                depth += 1
            } else if char == "]" || char == "}" {
                depth -= 1
            }
            previous = char
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Splits "key: value" (or "key:" at the end of the line) outside quotes and brackets.
    static func splitKey(_ content: String) -> (String, String)? {
        guard let first = content.first, first != "[", first != "{", !content.hasPrefix("- "), content != "-" else { return nil }
        var keyEnd: String.Index?
        if first == "\"" || first == "'" {
            guard let close = closingQuote(in: content, quote: first) else { return nil }
            keyEnd = content.index(after: close)
            guard keyEnd! < content.endIndex, content[keyEnd!] == ":" || content[keyEnd!] == " " else { return nil }
            let afterQuote = content[keyEnd!...].drop { $0 == " " }
            guard afterQuote.first == ":" else { return nil }
            keyEnd = afterQuote.startIndex
        } else {
            var position = content.startIndex
            while position < content.endIndex {
                if content[position] == ":" {
                    let next = content.index(after: position)
                    if next == content.endIndex || content[next] == " " {
                        keyEnd = position
                        break
                    }
                }
                position = content.index(after: position)
            }
        }
        guard let end = keyEnd else { return nil }
        let rawKey = content[..<end].trimmingCharacters(in: .whitespaces)
        let key = rawKey.first == "\"" || rawKey.first == "'" ? unquote(rawKey) : rawKey
        let rest = content[content.index(after: end)...].trimmingCharacters(in: .whitespaces)
        return (key, rest)
    }
}

private struct FlowParser {
    let chars: [Character]
    var index = 0
    let anchors: [String: Value]

    init(chars: [Character], anchors: [String: Value]) {
        self.chars = chars
        self.anchors = anchors
    }

    mutating func skip() {
        while index < chars.count, chars[index].isWhitespace { index += 1 }
    }

    mutating func value() throws -> Value {
        skip()
        guard index < chars.count else { return .null }
        switch chars[index] {
        case "[":
            index += 1
            var items: [Value] = []
            while true {
                skip()
                guard index < chars.count else { throw DataFormatError("Invalid YAML: unclosed [") }
                if chars[index] == "]" { index += 1; return .array(items) }
                items.append(try value())
                skip()
                if index < chars.count, chars[index] == "," { index += 1 }
            }
        case "{":
            index += 1
            var pairs: [(String, Value)] = []
            while true {
                skip()
                guard index < chars.count else { throw DataFormatError("Invalid YAML: unclosed {") }
                if chars[index] == "}" { index += 1; return .object(pairs) }
                let key = try scalar(stopAtColon: true).text
                skip()
                var item = Value.null
                if index < chars.count, chars[index] == ":" {
                    index += 1
                    item = try value()
                }
                pairs.append((key, item))
                skip()
                if index < chars.count, chars[index] == "," { index += 1 }
            }
        default:
            return try scalar(stopAtColon: false)
        }
    }

    mutating func scalar(stopAtColon: Bool) throws -> Value {
        skip()
        guard index < chars.count else { return .null }
        let first = chars[index]
        if first == "\"" || first == "'" {
            let rest = String(chars[index...])
            guard let close = YAMLParser.closingQuote(in: rest, quote: first) else {
                throw DataFormatError("Invalid YAML: unclosed quote")
            }
            let length = rest.distance(from: rest.startIndex, to: close) + 1
            index += length
            return .string(YAMLParser.unquote(String(rest.prefix(length))))
        }
        let start = index
        while index < chars.count {
            let char = chars[index]
            if char == "," || char == "]" || char == "}" { break }
            if stopAtColon, char == ":", index + 1 >= chars.count || chars[index + 1] == " " || chars[index + 1] == "," { break }
            index += 1
        }
        let text = String(chars[start..<index]).trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("*"), let aliased = anchors[String(text.dropFirst())] { return aliased }
        return YAMLParser.resolve(text)
    }
}
