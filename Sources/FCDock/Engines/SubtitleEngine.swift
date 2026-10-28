import Foundation

/// Subtitles (SRT, WebVTT, ASS/SSA, TTML) through a shared list of timed cues. Styling beyond
/// line breaks isn't carried across, since the formats style text in incompatible ways.
struct SubtitleEngine: Engine {
    let name = "Subtitles"

    private static let readable: Set<FileFormat> = [.srt, .vtt, .ass, .ssa, .ttml]
    private static let writable: Set<FileFormat> = [.srt, .vtt, .ass, .ssa, .ttml, .txt]

    struct Cue {
        var start: Double
        var end: Double
        var text: String
    }

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        from != to && Self.readable.contains(from) && Self.writable.contains(to) ? 10 : nil
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        let data = try Data(contentsOf: input)
        var text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        let cues: [Cue]
        switch from {
        case .srt, .vtt: cues = Self.readTimedBlocks(text)
        case .ass, .ssa: cues = Self.readASS(text)
        case .ttml: cues = try Self.readTTML(data)
        default: throw ConversionError.unsupported(input.lastPathComponent)
        }
        guard !cues.isEmpty else { throw ConversionError.exportFailed("no subtitles found in \(input.lastPathComponent)") }

        let result: String
        switch to {
        case .srt: result = Self.writeSRT(cues)
        case .vtt: result = Self.writeVTT(cues)
        case .ass, .ssa: result = Self.writeASS(cues, ssa: to == .ssa)
        case .ttml: result = Self.writeTTML(cues)
        default: result = cues.map(\.text).joined(separator: "\n\n") + "\n"
        }
        try Data(result.utf8).write(to: output)
    }

    // MARK: SRT and WebVTT

    /// Both are blocks separated by blank lines with a "start --> end" line; VTT adds a header and settings.
    private static func readTimedBlocks(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTime(parts[0]),
                  let end = parseTime(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0])
            else { continue }
            let body = lines[(timing + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(Cue(start: start, end: end, text: stripTags(body)))
        }
        return cues
    }

    /// "01:02:03,456", "01:02:03.456", "02:03.456" (VTT) or "0:02:03.45" (ASS).
    private static func parseTime(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!) else { return nil }
        let numbers = parts.dropLast().compactMap { Double($0) }
        guard numbers.count == parts.count - 1 else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 } * 60 + seconds
    }

    /// Drops <i>, <b>, <font>, VTT voice tags and the like, keeping the text.
    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func timestamp(_ seconds: Double, separator: String) -> String {
        let millis = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d\(separator)%03d", millis / 3_600_000, millis / 60_000 % 60, millis / 1000 % 60, millis % 1000)
    }

    private static func writeSRT(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    private static func writeVTT(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    // MARK: ASS and SSA

    private static func readASS(_ text: String) -> [Cue] {
        var format: [String] = []
        var cues: [Cue] = []
        var inEvents = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inEvents = line.lowercased() == "[events]"; continue }
            guard inEvents else { continue }
            if line.hasPrefix("Format:") {
                format = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if line.hasPrefix("Dialogue:"), !format.isEmpty {
                // Text is the last field and may itself contain commas.
                let fields = line.dropFirst(9).split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count == format.count,
                      let startIndex = format.firstIndex(of: "start"), let endIndex = format.firstIndex(of: "end"),
                      let textIndex = format.firstIndex(of: "text"),
                      let start = parseTime(fields[startIndex]), let end = parseTime(fields[endIndex]) else { continue }
                let body = fields[textIndex]
                    .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\h", with: " ")
                cues.append(Cue(start: start, end: end, text: body))
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func assTime(_ seconds: Double) -> String {
        let centis = Int((seconds * 100).rounded())
        return String(format: "%d:%02d:%02d.%02d", centis / 360_000, centis / 6000 % 60, centis / 100 % 60, centis % 100)
    }

    private static func writeASS(_ cues: [Cue], ssa: Bool) -> String {
        let events = cues.map { cue in
            let text = cue.text.replacingOccurrences(of: "\n", with: "\\N")
            let marked = ssa ? "Marked=0" : "0"
            return "Dialogue: \(marked),\(assTime(cue.start)),\(assTime(cue.end)),Default,,0,0,0,,\(text)"
        }.joined(separator: "\n")

        if ssa {
            return """
            [Script Info]
            ScriptType: v4.00
            PlayResX: 1920
            PlayResY: 1080

            [V4 Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
            Style: Default,Arial,64,16777215,65535,65535,0,0,0,1,3,0,2,40,40,50,0,1

            [Events]
            Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            \(events)

            """
        }
        return """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,64,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,3,0,2,40,40,50,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        \(events)

        """
    }

    // MARK: TTML

    private static func readTTML(_ data: Data) throws -> [Cue] {
        let document = try XMLDocument(data: data)
        let paragraphs = try document.nodes(forXPath: "//*[local-name()='p']").compactMap { $0 as? XMLElement }
        let frameRate = Double(document.rootElement()?.attribute(forName: "ttp:frameRate")?.stringValue ?? "") ?? 30
        return paragraphs.compactMap { paragraph in
            guard let begin = paragraph.attribute(forName: "begin")?.stringValue.flatMap({ ttmlTime($0, frameRate: frameRate) }) else { return nil }
            let end = paragraph.attribute(forName: "end")?.stringValue.flatMap { ttmlTime($0, frameRate: frameRate) }
                ?? paragraph.attribute(forName: "dur")?.stringValue.flatMap { ttmlTime($0, frameRate: frameRate) }.map { begin + $0 }
                ?? begin + 2
            return Cue(start: begin, end: end, text: ttmlText(paragraph).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// <br/> becomes a line break; other markup is dropped.
    private static func ttmlText(_ node: XMLNode) -> String {
        if node.kind == .text { return node.stringValue ?? "" }
        if node.localName == "br" { return "\n" }
        return (node.children ?? []).map(ttmlText).joined()
    }

    /// Clock time ("00:00:01.500", "00:00:01:12" with frames) or offset time ("1.5s", "1500ms", "90f").
    private static func ttmlTime(_ raw: String, frameRate: Double) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        for (unit, scale) in [("ms", 0.001), ("h", 3600), ("m", 60), ("s", 1), ("f", 1 / frameRate)] where value.hasSuffix(unit) {
            return Double(value.dropLast(unit.count)).map { $0 * scale }
        }
        let parts = value.split(separator: ":")
        if parts.count == 4, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]), let f = Double(parts[3]) {
            return h * 3600 + m * 60 + s + f / frameRate
        }
        return parseTime(value)
    }

    private static func writeTTML(_ cues: [Cue]) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let body = cues.map { cue in
            let text = cue.text.split(separator: "\n", omittingEmptySubsequences: false).map { escape(String($0)) }.joined(separator: "<br/>")
            return "      <p begin=\"\(timestamp(cue.start, separator: "."))\" end=\"\(timestamp(cue.end, separator: "."))\">\(text)</p>"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
          <body>
            <div>
        \(body)
            </div>
          </body>
        </tt>

        """
    }
}
