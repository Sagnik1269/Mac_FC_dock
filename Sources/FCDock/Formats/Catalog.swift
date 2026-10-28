import Foundation

/// What the wheel offers for each input format, most popular first (at most 8, one per arc).
/// A target only appears on the wheel when `Converter` has a way to make it on this Mac.
enum Catalog {
    private static let table = """
    # Documents
    doc     : docx pdf txt rtf odt html epub md
    docx    : pdf doc txt odt rtf html md epub
    odt     : docx pdf doc rtf txt html epub
    rtf     : docx pdf txt doc odt html md
    txt     : pdf docx md html rtf odt epub
    md      : html pdf docx txt epub odt rtf
    pdf     : docx txt jpg png html md epub svg
    pages   : pdf docx epub txt rtf
    tex     : pdf html docx epub txt
    html    : pdf docx md txt epub odt
    wps     : docx pdf doc rtf txt odt
    wpd     : docx pdf doc rtf txt
    docm    : docx pdf odt rtf txt

    # Images
    jpg     : png webp pdf avif tiff bmp gif heic
    png     : jpg webp pdf avif gif tiff ico bmp
    webp    : jpg png gif pdf avif tiff bmp
    gif     : mp4 webp png jpg apng webm
    bmp     : png jpg webp pdf tiff ico
    tiff    : jpg png pdf webp bmp avif
    svg     : png pdf jpg webp tiff ico
    heic    : jpg png pdf webp avif tiff
    avif    : jpg png webp pdf tiff
    ico     : png jpg webp bmp
    icns    : png ico jpg
    psd     : png jpg tiff pdf webp
    raw     : jpg tiff png webp
    exr     : png tiff jpg hdr
    hdr     : exr png tiff jpg
    tga     : png jpg tiff bmp
    jp2     : jpg png tiff pdf
    jxl     : jpg png webp avif tiff
    apng    : gif webp mp4 webm

    # Audio
    mp3     : wav flac aac m4a ogg opus aiff wma
    wav     : mp3 flac m4a aac ogg opus aiff
    flac    : mp3 wav m4a aac ogg opus alac
    aac     : mp3 wav m4a flac ogg opus
    m4a     : mp3 wav flac aac ogg opus
    ogg     : mp3 wav flac opus aac
    opus    : mp3 wav flac ogg aac
    wma     : mp3 wav flac aac m4a
    aiff    : wav mp3 flac aac m4a
    ape     : flac wav mp3 aac
    amr     : mp3 wav aac flac
    midi    : wav mp3 flac
    caf     : wav mp3 flac m4a
    ac3     : wav aac mp3 flac
    dts     : wav aac mp3 flac
    dsd     : wav flac aiff

    # Spreadsheets
    xls     : xlsx csv pdf ods tsv html
    xlsx    : pdf csv xls ods tsv json html
    xlsm    : xlsx pdf csv xls ods
    xlsb    : xlsx csv pdf xls ods
    ods     : xlsx pdf csv xls html
    csv     : xlsx json tsv pdf xml ods parquet html
    tsv     : csv xlsx json xml parquet
    numbers : xlsx csv pdf
    dbf     : csv xlsx json

    # Presentations
    ppt     : pptx pdf odp png jpg
    pptx    : pdf ppt png jpg odp svg
    pptm    : pptx pdf odp
    pps     : pptx pdf png jpg
    odp     : pptx pdf ppt png jpg
    key     : pdf pptx png jpg
    pot     : pptx pdf
    fodp    : odp pptx pdf

    # Data
    json    : yaml csv xml toml ndjson bson
    yaml    : json toml xml
    xml     : json yaml csv html
    toml    : json yaml xml
    ini     : json yaml toml
    ndjson  : json csv parquet
    parquet : csv json xlsx
    bson    : json yaml
    msgpack : json yaml bson
    sqlite  : sql csv json xlsx
    sql     : sqlite csv json

    # Subtitles
    srt     : vtt ass ssa txt ttml
    vtt     : srt ass ssa txt ttml
    ass     : srt vtt txt ttml
    ssa     : srt vtt txt ttml
    ttml    : srt vtt txt

    # Archives
    zip     : 7z tar tar.gz tar.xz tar.zst
    rar     : zip 7z tar tar.gz
    7z      : zip tar tar.gz tar.xz
    tar     : zip 7z tar.gz tar.xz tar.zst
    tar.gz  : zip 7z tar tar.xz
    tar.bz2 : zip 7z tar.gz
    tar.xz  : zip 7z tar.gz
    tar.zst : zip 7z tar.gz
    cab     : zip 7z tar
    iso     : zip 7z tar
    dmg     : zip 7z
    """

    static let menu: [FileFormat: [FileFormat]] = {
        var menu: [FileFormat: [FileFormat]] = [:]
        for line in table.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let source = FileFormat.with(id: parts[0].trimmingCharacters(in: .whitespaces)) else {
                assertionFailure("Bad catalog line: \(trimmed)")
                continue
            }
            menu[source] = parts[1].split(separator: " ").compactMap { id in
                let format = FileFormat.with(id: String(id))
                assert(format != nil, "Unknown format \(id) in catalog")
                return format
            }
        }
        return menu
    }()

    static func targets(for source: FileFormat) -> [FileFormat] {
        menu[source] ?? []
    }
}
