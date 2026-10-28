import Foundation

/// XML ⇄ tree with the common mapping: attributes become "@name" keys, mixed text "#text",
/// and repeated child elements become arrays.
enum XMLCodec {
    static func decode(_ data: Data) throws -> Value {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            let line = parser.lineNumber
            throw DataFormatError("Invalid XML on line \(line): \(parser.parserError?.localizedDescription ?? "couldn't parse")")
        }
        return .object([(root.name, root.value)])
    }

    static func encode(_ value: Value) -> String {
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>"]
        // A single top-level key names the root element; anything else goes inside <root>.
        if case .object(let pairs) = value, pairs.count == 1, !isArray(pairs[0].1) {
            element(pairs[0].0, pairs[0].1, indent: 0, into: &lines)
        } else if case .array(let items) = value {
            element("root", .object([("item", .array(items))]), indent: 0, into: &lines)
        } else {
            element("root", value, indent: 0, into: &lines)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func isArray(_ value: Value) -> Bool {
        if case .array = value { return true }
        return false
    }

    private static func element(_ rawName: String, _ value: Value, indent: Int, into lines: inout [String]) {
        let name = elementName(rawName)
        let pad = String(repeating: "  ", count: indent)
        switch value {
        case .array(let items):
            // Arrays repeat the element; an empty one leaves nothing.
            for item in items { element(rawName, item, indent: indent, into: &lines) }
        case .object(let pairs):
            var attributes = ""
            var text: String?
            var children: [(String, Value)] = []
            for (key, child) in pairs {
                if key.hasPrefix("@"), child.isScalar {
                    attributes += " \(elementName(String(key.dropFirst())))=\"\(escape(child.text, attribute: true))\""
                } else if key == "#text" {
                    text = child.text
                } else {
                    children.append((key, child))
                }
            }
            if children.isEmpty {
                if let text { lines.append("\(pad)<\(name)\(attributes)>\(escape(text))</\(name)>") } else { lines.append("\(pad)<\(name)\(attributes)/>") }
            } else {
                lines.append("\(pad)<\(name)\(attributes)>")
                if let text { lines.append(pad + "  " + escape(text)) }
                for (key, child) in children { element(key, child, indent: indent + 1, into: &lines) }
                lines.append("\(pad)</\(name)>")
            }
        case .null:
            lines.append("\(pad)<\(name)/>")
        default:
            lines.append("\(pad)<\(name)>\(escape(value.text))</\(name)>")
        }
    }

    /// Makes a key a valid element name: letters, digits, "_", "-" and ".", not starting with a digit.
    private static func elementName(_ key: String) -> String {
        var name = String(key.map { $0.isLetter || $0.isNumber || "_-.:".contains($0) ? $0 : "_" })
        if name.isEmpty { return "item" }
        if let first = name.first, first.isNumber || first == "-" || first == "." { name = "_" + name }
        return name
    }

    private static func escape(_ text: String, attribute: Bool = false) -> String {
        var result = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        if attribute { result = result.replacingOccurrences(of: "\"", with: "&quot;") }
        return result
    }

    // MARK: Reading

    private final class Node {
        let name: String
        var attributes: [(String, Value)]
        var children: [(String, Value)] = []
        var text = ""

        init(name: String, attributes: [String: String], order: [String]) {
            self.name = name
            self.attributes = order.compactMap { key in attributes[key].map { ("@" + key, Value.inferred($0)) } }
        }

        func add(_ name: String, _ value: Value) {
            // A repeated element turns its key into an array, in document order.
            if let index = children.firstIndex(where: { $0.0 == name }) {
                if case .array(var items) = children[index].1, repeatedNames.contains(name) {
                    items.append(value)
                    children[index].1 = .array(items)
                } else {
                    children[index].1 = .array([children[index].1, value])
                    repeatedNames.insert(name)
                }
            } else {
                children.append((name, value))
            }
        }

        private var repeatedNames = Set<String>()

        var value: Value {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if attributes.isEmpty, children.isEmpty {
                return trimmed.isEmpty ? .null : Value.inferred(trimmed)
            }
            var pairs = attributes + children
            if !trimmed.isEmpty { pairs.append(("#text", Value.inferred(trimmed))) }
            return .object(pairs)
        }
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [Node] = []
        var root: Node?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            // XMLParser hands attributes over unordered; sorting keeps output stable.
            stack.append(Node(name: name, attributes: attributes, order: attributes.keys.sorted()))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            stack.last?.text += String(decoding: block, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard let node = stack.popLast() else { return }
            if let parent = stack.last { parent.add(node.name, node.value) } else { root = node }
        }
    }
}

// MARK: - BSON

/// MongoDB's binary JSON. A file of several documents (as mongodump writes) reads as an array.
enum BSONCodec {
    static func decode(_ data: Data) throws -> Value {
        var reader = ByteReader(data)
        var documents: [Value] = []
        while !reader.atEnd { documents.append(try document(&reader, isArray: false)) }
        guard !documents.isEmpty else { throw DataFormatError("The BSON file is empty") }
        return documents.count == 1 ? documents[0] : .array(documents)
    }

    /// An array of documents is written one after another, like mongodump; anything else as one document.
    static func encode(_ value: Value) -> Data {
        switch value {
        case .array(let items) where items.allSatisfy({ if case .object = $0 { return true }; return false }):
            return items.reduce(into: Data()) { $0 += document($1) }
        case .object:
            return document(value)
        default:
            return document(.object([("value", value)]))
        }
    }

    private static func document(_ reader: inout ByteReader, isArray: Bool) throws -> Value {
        let start = reader.offset
        let length = Int(try reader.int32())
        let end = start + length
        var pairs: [(String, Value)] = []
        while reader.offset < end - 1 {
            let type = try reader.byte()
            let name = try reader.cString()
            pairs.append((name, try element(type, &reader)))
        }
        _ = try reader.byte()  // terminating 0
        return isArray ? .array(pairs.map(\.1)) : .object(pairs)
    }

    private static func element(_ type: UInt8, _ reader: inout ByteReader) throws -> Value {
        switch type {
        case 0x01: return .double(Double(bitPattern: try reader.uint64()))
        case 0x02, 0x0D, 0x0E:
            let length = Int(try reader.int32())
            let bytes = try reader.bytes(length)
            return .string(String(decoding: bytes.dropLast(), as: UTF8.self))
        case 0x03: return try document(&reader, isArray: false)
        case 0x04: return try document(&reader, isArray: true)
        case 0x05:
            let length = Int(try reader.int32())
            _ = try reader.byte()  // subtype
            return .string(try reader.bytes(length).base64EncodedString())
        case 0x06, 0x0A, 0xFF, 0x7F: return .null
        case 0x07: return .string(try reader.bytes(12).map { String(format: "%02x", $0) }.joined())
        case 0x08: return .bool(try reader.byte() != 0)
        case 0x09:
            let millis = Int64(bitPattern: try reader.uint64())
            let date = Date(timeIntervalSince1970: Double(millis) / 1000)
            return .string(ISO8601DateFormatter().string(from: date))
        case 0x0B:
            let pattern = try reader.cString()
            let options = try reader.cString()
            return .string("/\(pattern)/\(options)")
        case 0x10: return .int(Int64(try reader.int32()))
        case 0x11, 0x12: return .int(Int64(bitPattern: try reader.uint64()))
        case 0x13: return .string(try reader.bytes(16).map { String(format: "%02x", $0) }.joined())
        default: throw DataFormatError("Unsupported BSON type 0x\(String(type, radix: 16))")
        }
    }

    private static func document(_ value: Value) -> Data {
        var body = Data()
        let pairs: [(String, Value)]
        switch value {
        case .object(let object): pairs = object
        case .array(let items): pairs = items.enumerated().map { (String($0.offset), $0.element) }
        default: pairs = []
        }
        for (key, item) in pairs {
            let (type, payload) = element(item)
            body.append(type)
            body += Data(key.utf8) + [0]
            body += payload
        }
        body.append(0)
        return littleEndian(Int32(body.count + 4)) + body
    }

    private static func element(_ value: Value) -> (UInt8, Data) {
        switch value {
        case .null: return (0x0A, Data())
        case .bool(let bool): return (0x08, Data([bool ? 1 : 0]))
        case .int(let int):
            if let small = Int32(exactly: int) { return (0x10, littleEndian(small)) }
            return (0x12, littleEndian(int))
        case .double(let double): return (0x01, littleEndian(double.bitPattern))
        case .string(let string):
            let bytes = Data(string.utf8)
            return (0x02, littleEndian(Int32(bytes.count + 1)) + bytes + [0])
        case .array: return (0x04, document(value))
        case .object: return (0x03, document(value))
        }
    }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

private struct ByteReader {
    let data: [UInt8]
    var offset = 0

    init(_ data: Data) { self.data = Array(data) }

    var atEnd: Bool { offset >= data.count }

    mutating func byte() throws -> UInt8 {
        guard offset < data.count else { throw DataFormatError("The file ends unexpectedly") }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw DataFormatError("The file ends unexpectedly") }
        defer { offset += count }
        return Data(data[offset..<offset + count])
    }

    mutating func int32() throws -> Int32 {
        let raw = try bytes(4)
        return Int32(bitPattern: raw.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) })
    }

    mutating func uint64() throws -> UInt64 {
        let raw = try bytes(8)
        return raw.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    mutating func bigEndian(_ count: Int) throws -> UInt64 {
        try bytes(count).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    mutating func cString() throws -> String {
        guard let end = data[offset...].firstIndex(of: 0) else { throw DataFormatError("The file ends unexpectedly") }
        defer { offset = end + 1 }
        return String(decoding: data[offset..<end], as: UTF8.self)
    }
}

// MARK: - MessagePack

enum MessagePackCodec {
    /// Several values back to back (a stream) read as an array.
    static func decode(_ data: Data) throws -> Value {
        var reader = ByteReader(data)
        var values: [Value] = []
        while !reader.atEnd { values.append(try value(&reader)) }
        guard !values.isEmpty else { throw DataFormatError("The MessagePack file is empty") }
        return values.count == 1 ? values[0] : .array(values)
    }

    private static func value(_ reader: inout ByteReader) throws -> Value {
        let byte = try reader.byte()
        switch byte {
        case 0x00...0x7F: return .int(Int64(byte))
        case 0x80...0x8F: return try map(Int(byte & 0x0F), &reader)
        case 0x90...0x9F: return try array(Int(byte & 0x0F), &reader)
        case 0xA0...0xBF: return try string(Int(byte & 0x1F), &reader)
        case 0xC0: return .null
        case 0xC2: return .bool(false)
        case 0xC3: return .bool(true)
        case 0xC4, 0xC5, 0xC6:
            let length = Int(try reader.bigEndian(1 << Int(byte - 0xC4)))
            return .string(try reader.bytes(length).base64EncodedString())
        case 0xC7, 0xC8, 0xC9:
            // Extension types (timestamps etc.): keep the payload as base64.
            let length = Int(try reader.bigEndian(1 << Int(byte - 0xC7)))
            _ = try reader.byte()
            return .string(try reader.bytes(length).base64EncodedString())
        case 0xCA: return .double(Double(Float(bitPattern: UInt32(try reader.bigEndian(4)))))
        case 0xCB: return .double(Double(bitPattern: try reader.bigEndian(8)))
        case 0xCC, 0xCD, 0xCE: return .int(Int64(try reader.bigEndian(1 << Int(byte - 0xCC))))
        case 0xCF: return .int(Int64(bitPattern: try reader.bigEndian(8)))
        case 0xD0: return .int(Int64(Int8(bitPattern: UInt8(try reader.bigEndian(1)))))
        case 0xD1: return .int(Int64(Int16(bitPattern: UInt16(try reader.bigEndian(2)))))
        case 0xD2: return .int(Int64(Int32(bitPattern: UInt32(try reader.bigEndian(4)))))
        case 0xD3: return .int(Int64(bitPattern: try reader.bigEndian(8)))
        case 0xD4...0xD8:
            let length = 1 << Int(byte - 0xD4)
            _ = try reader.byte()
            return .string(try reader.bytes(length).base64EncodedString())
        case 0xD9, 0xDA, 0xDB: return try string(Int(try reader.bigEndian(1 << Int(byte - 0xD9))), &reader)
        case 0xDC, 0xDD: return try array(Int(try reader.bigEndian(byte == 0xDC ? 2 : 4)), &reader)
        case 0xDE, 0xDF: return try map(Int(try reader.bigEndian(byte == 0xDE ? 2 : 4)), &reader)
        case 0xE0...0xFF: return .int(Int64(Int8(bitPattern: byte)))
        default: throw DataFormatError("Invalid MessagePack byte 0x\(String(byte, radix: 16))")
        }
    }

    private static func string(_ length: Int, _ reader: inout ByteReader) throws -> Value {
        .string(String(decoding: try reader.bytes(length), as: UTF8.self))
    }

    private static func array(_ count: Int, _ reader: inout ByteReader) throws -> Value {
        .array(try (0..<count).map { _ in try value(&reader) })
    }

    private static func map(_ count: Int, _ reader: inout ByteReader) throws -> Value {
        .object(try (0..<count).map { _ in (try value(&reader).text, try value(&reader)) })
    }

    static func encode(_ value: Value) -> Data {
        switch value {
        case .null: return Data([0xC0])
        case .bool(let bool): return Data([bool ? 0xC3 : 0xC2])
        case .int(let int):
            if (0...0x7F).contains(int) { return Data([UInt8(int)]) }
            if (-32..<0).contains(int) { return Data([UInt8(bitPattern: Int8(int))]) }
            if let small = Int8(exactly: int) { return Data([0xD0]) + bigEndian(small) }
            if let small = Int16(exactly: int) { return Data([0xD1]) + bigEndian(small) }
            if let small = Int32(exactly: int) { return Data([0xD2]) + bigEndian(small) }
            return Data([0xD3]) + bigEndian(int)
        case .double(let double): return Data([0xCB]) + bigEndian(double.bitPattern)
        case .string(let string):
            let bytes = Data(string.utf8)
            return header(bytes.count, fix: 0xA0, fixLimit: 32, small: [0xD9, 0xDA, 0xDB]) + bytes
        case .array(let items):
            return items.reduce(into: header(items.count, fix: 0x90, fixLimit: 16, small: [nil, 0xDC, 0xDD])) { $0 += encode($1) }
        case .object(let pairs):
            return pairs.reduce(into: header(pairs.count, fix: 0x80, fixLimit: 16, small: [nil, 0xDE, 0xDF])) {
                $0 += encode(.string($1.0)) + encode($1.1)
            }
        }
    }

    /// The type byte and length; `small` holds the 8-, 16- and 32-bit length markers.
    private static func header(_ count: Int, fix: UInt8, fixLimit: Int, small: [UInt8?]) -> Data {
        if count < fixLimit { return Data([fix | UInt8(count)]) }
        if let marker = small[0], count <= 0xFF { return Data([marker, UInt8(count)]) }
        if let marker = small[1], count <= 0xFFFF { return Data([marker]) + bigEndian(UInt16(count)) }
        return Data([small[2]!]) + bigEndian(UInt32(count))
    }
}
