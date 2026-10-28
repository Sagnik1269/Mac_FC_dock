import AppKit

/// An app or command-line tool an engine depends on. Found by looking in the usual install
/// locations, because apps opened from Finder don't get Homebrew's PATH.
struct Tool: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A command-line program; the paths are checked in order.
        case command([String])
        /// A Mac app, by bundle ID.
        case app(String)
    }

    let id: String
    let name: String
    /// What it unlocks, for the dashboard.
    let purpose: String
    /// A shell command that installs it, or nil when it comes from the App Store.
    let install: String?
    let kind: Kind

    /// The executable (or app bundle) to use, if it's installed.
    var location: URL? {
        switch kind {
        case .command(let paths):
            return paths.lazy.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
        case .app(let bundleID):
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
    }

    var isInstalled: Bool { location != nil }

    /// The executable's path. Engines only run when their tool is installed, so this is safe to use there.
    var path: String { location?.path ?? "" }

    private static func homebrew(_ name: String) -> Kind {
        .command(["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"])
    }
}

extension Tool {
    static let pages = Tool(id: "pages", name: "Pages", purpose: "Word → PDF with the original layout, Pages documents, EPUB",
                            install: nil, kind: .app("com.apple.iWork.Pages"))
    static let numbers = Tool(id: "numbers", name: "Numbers", purpose: "Excel, CSV and Numbers spreadsheets → XLSX, CSV, PDF",
                              install: nil, kind: .app("com.apple.iWork.Numbers"))
    static let keynote = Tool(id: "keynote", name: "Keynote", purpose: "PowerPoint and Keynote → PDF, PPTX, slide images",
                              install: nil, kind: .app("com.apple.iWork.Keynote"))
    static let libreOffice = Tool(
        id: "libreoffice", name: "LibreOffice",
        purpose: "ODT, ODS, ODP, WPS, WPD, XLSB, DBF, old Office formats (DOC, XLS, PPT) as outputs, PPTX → SVG",
        install: "brew install --cask libreoffice",
        kind: .command([
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice",
        ])
    )
    static let pandoc = Tool(id: "pandoc", name: "pandoc", purpose: "Markdown, EPUB and LaTeX",
                             install: "brew install pandoc", kind: homebrew("pandoc"))
    static let ffmpeg = Tool(id: "ffmpeg", name: "FFmpeg", purpose: "MP3, OGG, OPUS, WMA, APE, DTS, DSD audio; GIF → MP4/WebM",
                             install: "brew install ffmpeg", kind: homebrew("ffmpeg"))
    static let imageMagick = Tool(id: "imagemagick", name: "ImageMagick", purpose: "WebP, JPEG XL and HDR export",
                                  install: "brew install imagemagick", kind: homebrew("magick"))
    static let poppler = Tool(id: "poppler", name: "Poppler", purpose: "PDF → SVG",
                              install: "brew install poppler", kind: homebrew("pdftocairo"))
    static let duckdb = Tool(id: "duckdb", name: "DuckDB", purpose: "Parquet",
                             install: "brew install duckdb", kind: homebrew("duckdb"))
    static let tectonic = Tool(id: "tectonic", name: "Tectonic", purpose: "LaTeX → PDF with proper typesetting",
                               install: "brew install tectonic", kind: homebrew("tectonic"))

    /// In the order the dashboard lists them.
    static let all: [Tool] = [pages, numbers, keynote, ffmpeg, pandoc, libreOffice, imageMagick, poppler, duckdb, tectonic]
}
