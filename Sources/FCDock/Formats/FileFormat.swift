import Foundation
import ImageIO

enum FormatCategory {
    case document, image, video, audio, spreadsheet, presentation, ebook, data, subtitle, archive
}

/// A file format FC Dock knows about. Which conversions are offered for it lives in `Catalog`;
/// which of those this Mac can actually do is decided by the engines in `Converter`.
struct FileFormat: Hashable, Identifiable, CustomStringConvertible {
    /// Lowercase and unique, e.g. "docx" or "tar.gz".
    let id: String
    let label: String
    /// The first one is used for new files.
    let extensions: [String]
    let category: FormatCategory
    let symbol: String

    init(_ id: String, _ category: FormatCategory, _ symbol: String, label: String? = nil, extensions: [String]? = nil) {
        self.id = id
        self.label = label ?? id.uppercased()
        self.extensions = extensions ?? [id]
        self.category = category
        self.symbol = symbol
    }

    var fileExtension: String { extensions[0] }
    /// Goes into output names: "Report_pdf.pdf", "Backup_targz.tar.gz".
    var suffix: String { id.replacingOccurrences(of: ".", with: "") }
    var description: String { label }

    var isImage: Bool { category == .image }
    var isAudio: Bool { category == .audio }

    static func == (lhs: FileFormat, rhs: FileFormat) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: Lookup

    static func with(id: String) -> FileFormat? { byID[id] }

    /// The format of a file on disk, from its extension. Animated PNGs are told apart from still ones.
    static func detect(_ url: URL) -> FileFormat? {
        let name = url.lastPathComponent.lowercased()
        // Two-part extensions such as .tar.gz first.
        for (ext, format) in compoundExtensions where name.hasSuffix("." + ext) {
            return format
        }
        guard let format = byExtension[url.pathExtension.lowercased()] else { return nil }
        if format == .png, isAnimated(url) { return .apng }
        return format
    }

    /// The file name without its format's extension ("Backup" for "Backup.tar.gz").
    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        if let format = detect(url),
           let ext = format.extensions.first(where: { name.lowercased().hasSuffix("." + $0) }) {
            return String(name.dropLast(ext.count + 1))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func isAnimated(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    private static let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    // First format listed wins, so "png" means PNG rather than APNG and "m4a" means M4A rather than ALAC.
    private static let byExtension: [String: FileFormat] = {
        var map: [String: FileFormat] = [:]
        for format in all {
            for ext in format.extensions where map[ext] == nil { map[ext] = format }
        }
        return map
    }()

    private static let compoundExtensions: [(String, FileFormat)] =
        all.flatMap { format in format.extensions.filter { $0.contains(".") }.map { ($0, format) } }
}

// MARK: - Known formats

extension FileFormat {
    // Documents
    static let doc = FileFormat("doc", .document, "doc.text")
    static let docx = FileFormat("docx", .document, "doc.text.fill")
    static let docm = FileFormat("docm", .document, "doc.badge.gearshape")
    static let odt = FileFormat("odt", .document, "doc.plaintext")
    static let rtf = FileFormat("rtf", .document, "textformat")
    static let txt = FileFormat("txt", .document, "text.alignleft", extensions: ["txt", "text"])
    static let md = FileFormat("md", .document, "number", extensions: ["md", "markdown"])
    static let pdf = FileFormat("pdf", .document, "doc.richtext")
    static let pages = FileFormat("pages", .document, "doc.append", label: "Pages")
    static let tex = FileFormat("tex", .document, "function", extensions: ["tex", "latex"])
    static let html = FileFormat("html", .document, "chevron.left.forwardslash.chevron.right", extensions: ["html", "htm"])
    static let wps = FileFormat("wps", .document, "doc.text.below.ecg")
    static let wpd = FileFormat("wpd", .document, "doc.on.doc")
    static let epub = FileFormat("epub", .ebook, "book")

    // Images
    static let jpg = FileFormat("jpg", .image, "photo.fill", extensions: ["jpg", "jpeg", "jpe"])
    static let png = FileFormat("png", .image, "photo")
    static let webp = FileFormat("webp", .image, "globe")
    static let gif = FileFormat("gif", .image, "photo.stack")
    static let bmp = FileFormat("bmp", .image, "square.grid.3x3")
    static let tiff = FileFormat("tiff", .image, "photo.artframe", extensions: ["tiff", "tif"])
    static let svg = FileFormat("svg", .image, "scribble.variable")
    static let heic = FileFormat("heic", .image, "photo.on.rectangle", extensions: ["heic", "heif"])
    static let avif = FileFormat("avif", .image, "sparkles")
    static let ico = FileFormat("ico", .image, "app.dashed")
    static let icns = FileFormat("icns", .image, "app.gift", label: "ICNS")
    static let psd = FileFormat("psd", .image, "square.3.layers.3d")
    static let raw = FileFormat("raw", .image, "camera.aperture", label: "RAW",
                                extensions: ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "raw"])
    static let exr = FileFormat("exr", .image, "sun.max")
    static let hdr = FileFormat("hdr", .image, "sun.max.fill")
    static let tga = FileFormat("tga", .image, "gamecontroller")
    static let jp2 = FileFormat("jp2", .image, "photo.badge.checkmark", extensions: ["jp2", "j2k", "jpf"])
    static let jxl = FileFormat("jxl", .image, "photo.badge.plus")
    static let apng = FileFormat("apng", .image, "play.rectangle.on.rectangle", label: "APNG", extensions: ["png", "apng"])

    // Video (only produced from animated images for now)
    static let mp4 = FileFormat("mp4", .video, "film")
    static let webm = FileFormat("webm", .video, "play.rectangle")

    // Audio
    static let mp3 = FileFormat("mp3", .audio, "music.note")
    static let wav = FileFormat("wav", .audio, "waveform.path")
    static let flac = FileFormat("flac", .audio, "waveform.circle")
    static let aac = FileFormat("aac", .audio, "waveform")
    static let m4a = FileFormat("m4a", .audio, "music.note.list")
    static let ogg = FileFormat("ogg", .audio, "waveform.path.ecg", extensions: ["ogg", "oga"])
    static let opus = FileFormat("opus", .audio, "mic")
    static let wma = FileFormat("wma", .audio, "music.quarternote.3")
    static let aiff = FileFormat("aiff", .audio, "hifispeaker", extensions: ["aiff", "aif", "aifc"])
    static let alac = FileFormat("alac", .audio, "music.note.house", label: "ALAC", extensions: ["m4a"])
    static let ape = FileFormat("ape", .audio, "waveform.badge.plus")
    static let amr = FileFormat("amr", .audio, "phone")
    static let midi = FileFormat("midi", .audio, "pianokeys", label: "MIDI", extensions: ["mid", "midi"])
    static let caf = FileFormat("caf", .audio, "waveform.badge.mic")
    static let ac3 = FileFormat("ac3", .audio, "speaker.wave.3", extensions: ["ac3", "eac3"])
    static let dts = FileFormat("dts", .audio, "hifispeaker.2")
    static let dsd = FileFormat("dsd", .audio, "opticaldisc", label: "DSD", extensions: ["dsf", "dff"])

    // Spreadsheets
    static let xls = FileFormat("xls", .spreadsheet, "tablecells")
    static let xlsx = FileFormat("xlsx", .spreadsheet, "tablecells.fill")
    static let xlsm = FileFormat("xlsm", .spreadsheet, "tablecells.badge.ellipsis")
    static let xlsb = FileFormat("xlsb", .spreadsheet, "square.grid.3x2")
    static let ods = FileFormat("ods", .spreadsheet, "square.grid.3x3.square")
    static let csv = FileFormat("csv", .spreadsheet, "list.bullet.rectangle")
    static let tsv = FileFormat("tsv", .spreadsheet, "list.bullet.indent", extensions: ["tsv", "tab"])
    static let numbers = FileFormat("numbers", .spreadsheet, "chart.bar.doc.horizontal", label: "Numbers")
    static let dbf = FileFormat("dbf", .spreadsheet, "cylinder")

    // Presentations
    static let ppt = FileFormat("ppt", .presentation, "rectangle.on.rectangle")
    static let pptx = FileFormat("pptx", .presentation, "rectangle.fill.on.rectangle.fill")
    static let pptm = FileFormat("pptm", .presentation, "rectangle.on.rectangle.badge.gearshape")
    static let pps = FileFormat("pps", .presentation, "play.display", label: "PPSX", extensions: ["ppsx", "pps"])
    static let odp = FileFormat("odp", .presentation, "rectangle.stack")
    static let key = FileFormat("key", .presentation, "play.rectangle.on.rectangle.fill", label: "Keynote")
    static let pot = FileFormat("pot", .presentation, "rectangle.dashed", label: "POTX", extensions: ["potx", "pot"])
    static let fodp = FileFormat("fodp", .presentation, "rectangle.stack.badge.person.crop")

    // Data
    static let json = FileFormat("json", .data, "curlybraces")
    static let yaml = FileFormat("yaml", .data, "list.dash", extensions: ["yaml", "yml"])
    static let xml = FileFormat("xml", .data, "chevron.left.slash.chevron.right")
    static let toml = FileFormat("toml", .data, "square.and.pencil")
    static let ini = FileFormat("ini", .data, "gearshape", extensions: ["ini", "cfg", "conf"])
    static let ndjson = FileFormat("ndjson", .data, "list.bullet", label: "NDJSON", extensions: ["ndjson", "jsonl"])
    static let parquet = FileFormat("parquet", .data, "square.stack.3d.up", label: "Parquet")
    static let bson = FileFormat("bson", .data, "curlybraces.square")
    static let msgpack = FileFormat("msgpack", .data, "shippingbox", label: "MsgPack", extensions: ["msgpack", "mpk"])
    static let sqlite = FileFormat("sqlite", .data, "cylinder.split.1x2", label: "SQLite", extensions: ["sqlite", "sqlite3", "db"])
    static let sql = FileFormat("sql", .data, "terminal")

    // Subtitles
    static let srt = FileFormat("srt", .subtitle, "captions.bubble")
    static let vtt = FileFormat("vtt", .subtitle, "captions.bubble.fill")
    static let ass = FileFormat("ass", .subtitle, "text.bubble")
    static let ssa = FileFormat("ssa", .subtitle, "text.bubble.fill")
    static let ttml = FileFormat("ttml", .subtitle, "text.word.spacing", extensions: ["ttml", "dfxp"])

    // Archives
    static let zip = FileFormat("zip", .archive, "doc.zipper")
    static let rar = FileFormat("rar", .archive, "archivebox")
    static let sevenZip = FileFormat("7z", .archive, "archivebox.fill")
    static let tar = FileFormat("tar", .archive, "shippingbox")
    static let tarGz = FileFormat("tar.gz", .archive, "shippingbox.fill", label: "TAR.GZ", extensions: ["tar.gz", "tgz"])
    static let tarBz2 = FileFormat("tar.bz2", .archive, "cube", label: "TAR.BZ2", extensions: ["tar.bz2", "tbz2", "tbz"])
    static let tarXz = FileFormat("tar.xz", .archive, "cube.fill", label: "TAR.XZ", extensions: ["tar.xz", "txz"])
    static let tarZst = FileFormat("tar.zst", .archive, "bolt.horizontal", label: "TAR.ZST", extensions: ["tar.zst", "tzst"])
    static let cab = FileFormat("cab", .archive, "tray.full")
    static let iso = FileFormat("iso", .archive, "opticaldiscdrive")
    static let dmg = FileFormat("dmg", .archive, "externaldrive")

    /// Every known format. Order matters for extensions shared by two formats (see `byExtension`).
    static let all: [FileFormat] = [
        doc, docx, docm, odt, rtf, txt, md, pdf, pages, tex, html, wps, wpd, epub,
        jpg, png, webp, gif, bmp, tiff, svg, heic, avif, ico, icns, psd, raw, exr, hdr, tga, jp2, jxl, apng,
        mp4, webm,
        mp3, wav, flac, aac, m4a, ogg, opus, wma, aiff, alac, ape, amr, midi, caf, ac3, dts, dsd,
        xls, xlsx, xlsm, xlsb, ods, csv, tsv, numbers, dbf,
        ppt, pptx, pptm, pps, odp, key, pot, fodp,
        json, yaml, xml, toml, ini, ndjson, parquet, bson, msgpack, sqlite, sql,
        srt, vtt, ass, ssa, ttml,
        zip, rar, sevenZip, tar, tarGz, tarBz2, tarXz, tarZst, cab, iso, dmg,
    ]
}
