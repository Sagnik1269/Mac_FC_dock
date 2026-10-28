import Foundation

/// A format-neutral tree that every data format reads into and writes out of.
/// Objects keep their key order, so a round trip doesn't shuffle a config file.
indirect enum Value: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([Value])
    case object([(String, Value)])

    static func == (lhs: Value, rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)): return a.map(\.0) == b.map(\.0) && a.map(\.1) == b.map(\.1)
        default: return false
        }
    }

    subscript(key: String) -> Value? {
        if case .object(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    var isScalar: Bool {
        switch self {
        case .array, .object: return false
        default: return true
        }
    }

    /// The scalar as text, for CSV cells, XML text and the like.
    var text: String {
        switch self {
        case .null: return ""
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return Value.format(value)
        case .string(let value): return value
        case .array, .object: return (try? JSONCodec.encode(self, pretty: false)) ?? ""
        }
    }

    static func format(_ number: Double) -> String {
        if number.isNaN { return "nan" }
        if number.isInfinite { return number > 0 ? "inf" : "-inf" }
        if number == number.rounded(), abs(number) < 1e15 { return String(format: "%.1f", number) }
        return String(number)
    }

    /// Reads a bare word the way CSV, INI and XML values are usually meant: numbers and booleans become typed.
    static func inferred(_ text: String) -> Value {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: break
        }
        // Keep leading zeros ("007", ZIP codes) and "+1…" phone numbers as text.
        let leadingZero = trimmed.count > 1 && trimmed.hasPrefix("0") && !trimmed.hasPrefix("0.")
        if !leadingZero, !trimmed.hasPrefix("+"), !trimmed.isEmpty {
            if let int = Int64(trimmed) { return .int(int) }
            if trimmed.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }),
               trimmed.allSatisfy({ "0123456789.eE-+".contains($0) }), let double = Double(trimmed) {
                return .double(double)
            }
        }
        return .string(text)
    }
}

// MARK: - Tables

/// Rows and columns for CSV, TSV and HTML tables.
struct Table {
    var columns: [String]
    var rows: [[Value]]

    /// Flattens a tree into a table: an array of objects becomes one row per object, nested values become
    /// dotted columns ("address.city"), and wrapper objects around a single array (as XML produces,
    /// e.g. <people><person>…</person>…</people>) are looked through.
    init(_ value: Value) {
        var unwrapped = value
        while case .object(let pairs) = unwrapped, pairs.count == 1, !pairs[0].1.isScalar {
            unwrapped = pairs[0].1
        }
        let records: [Value]
        if case .array(let items) = unwrapped { records = items } else { records = [value] }

        var columns: [String] = []
        var seen = Set<String>()
        var flatRows: [[(String, Value)]] = []
        for record in records {
            var flat: [(String, Value)] = []
            Self.flatten(record, prefix: "", into: &flat)
            for (key, _) in flat where seen.insert(key).inserted { columns.append(key) }
            flatRows.append(flat)
        }
        self.columns = columns
        rows = flatRows.map { flat in
            let lookup = Dictionary(flat, uniquingKeysWith: { first, _ in first })
            return columns.map { lookup[$0] ?? .null }
        }
    }

    init(columns: [String], rows: [[Value]]) {
        self.columns = columns
        self.rows = rows
    }

    private static func flatten(_ value: Value, prefix: String, into result: inout [(String, Value)]) {
        switch value {
        case .object(let pairs) where !pairs.isEmpty:
            for (key, child) in pairs { flatten(child, prefix: prefix.isEmpty ? key : "\(prefix).\(key)", into: &result) }
        case .array(let items) where items.allSatisfy(\.isScalar):
            // A list of plain values fits in one cell.
            result.append((prefix.isEmpty ? "value" : prefix, .string(items.map(\.text).joined(separator: ", "))))
        default:
            result.append((prefix.isEmpty ? "value" : prefix, value))
        }
    }

    /// One object per row, with values typed where they look like numbers or booleans.
    var value: Value {
        .array(rows.map { row in
            .object(zip(columns, row).map { column, cell in
                if case .string(let text) = cell { return (column, Value.inferred(text)) }
                return (column, cell)
            })
        })
    }
}
