import AppKit
import ImageIO
import PDFKit

/// Images through macOS's own codecs (ImageIO), plus SVG via AppKit and PDF via PDFKit.
/// What it can read and write is asked of ImageIO at launch, so it grows with macOS.
struct ImageIOEngine: Engine {
    let name = "ImageIO"

    private static let identifiers: [FileFormat: String] = [
        .jpg: "public.jpeg", .png: "public.png", .apng: "public.png", .heic: "public.heic", .tiff: "public.tiff",
        .gif: "com.compuserve.gif", .bmp: "com.microsoft.bmp", .webp: "org.webmproject.webp", .avif: "public.avif",
        .ico: "com.microsoft.ico", .icns: "com.apple.icns", .psd: "com.adobe.photoshop-image",
        .tga: "com.truevision.tga-image", .exr: "com.ilm.openexr-image", .hdr: "public.radiance",
        .jp2: "public.jpeg-2000", .jxl: "public.jpeg-xl",
    ]

    private static let readable: Set<FileFormat> = {
        let types = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        var formats = Set(identifiers.filter { types.contains($0.value) }.keys)
        // Camera RAW comes as one type per manufacturer; any of them means RAW decoding is there.
        if types.contains(where: { $0.hasSuffix("raw-image") }) { formats.insert(.raw) }
        formats.formUnion([.svg, .pdf])
        return formats
    }()

    private static let writable: Set<FileFormat> = {
        let types = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        var formats = Set(identifiers.filter { types.contains($0.value) }.keys)
        formats.insert(.pdf)
        return formats
    }()

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        guard from != to, Self.readable.contains(from), Self.writable.contains(to) else { return nil }
        // Only GIF ⇄ APNG keep the animation; APNG is only offered as a target for GIFs.
        if to == .apng { return from == .gif ? 10 : nil }
        if from == .pdf { return to.isImage ? 10 : nil }
        guard from.isImage else { return nil }
        return 10
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        switch (from, to) {
        case (.svg, .pdf):
            try Self.writeVectorPDF(svg: input, to: output)
        case (_, .pdf):
            try Self.writePDF(image: Self.orientedImage(at: input), dpi: Self.dpi(of: input), to: output)
        case (.gif, .apng), (.apng, .gif):
            try Self.copyAnimation(input, to: to, output: output)
        case (_, .ico), (_, .icns):
            try Self.writeIcon(Self.image(from: input, as: from), as: to, to: output)
        case (.svg, _), (.pdf, _):
            try Self.write(Self.image(from: input, as: from), as: to, to: output)
        default:
            try Self.reencode(input, as: to, to: output)
        }
    }

    /// The picture to convert: SVGs and PDFs are rendered, other images decoded.
    private static func image(from input: URL, as format: FileFormat) throws -> CGImage {
        switch format {
        case .svg: return try renderSVG(input)
        case .pdf: return try renderFirstPage(of: input)
        default: return try orientedImage(at: input)
        }
    }

    // MARK: Image → image

    private static func reencode(_ source: URL, as format: FileFormat, to output: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw ConversionError.unreadable(source.lastPathComponent)
        }
        let index = largestImageIndex(imageSource)
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [CFString: Any] ?? [:]
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let depth = properties[kCGImagePropertyDepth] as? Int ?? 8

        // Re-render when the target can't hold transparency (clear pixels would turn black), or when the
        // source is high bit depth or RAW and the target is 8-bit, so it's tone-mapped rather than clipped.
        if (hasAlpha && !format.supportsAlpha) || depth > 8 || index != 0 {
            try write(orientedImage(from: imageSource, index: index), as: format, to: output)
            return
        }

        // Copying straight from the source keeps metadata such as EXIF and orientation.
        let destination = try makeDestination(output, format)
        CGImageDestinationAddImageFromSource(destination, imageSource, index, encodingOptions as CFDictionary)
        try finalize(destination, output)
    }

    static func write(_ image: CGImage, as format: FileFormat, to output: URL) throws {
        let destination = try makeDestination(output, format)
        let image = format.supportsAlpha ? image : flattenedOnWhite(image)
        CGImageDestinationAddImage(destination, image, encodingOptions as CFDictionary)
        try finalize(destination, output)
    }

    private static let encodingOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]

    private static func makeDestination(_ url: URL, _ format: FileFormat, count: Int = 1) throws -> CGImageDestination {
        guard let type = identifiers[format],
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, count, nil) else {
            throw ConversionError.exportFailed("this Mac can't write \(format.label)")
        }
        return destination
    }

    private static func finalize(_ destination: CGImageDestination, _ url: URL) throws {
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw ConversionError.exportFailed("couldn't encode \(url.lastPathComponent)")
        }
    }

    // MARK: Icons

    /// Icons hold several square sizes; the image is centred on a transparent square first.
    private static func writeIcon(_ image: CGImage, as format: FileFormat, to output: URL) throws {
        let longest = max(image.width, image.height)
        let candidates = format == .icns ? [1024, 512, 256, 128, 64, 32, 16] : [256, 128, 64, 48, 32, 16]
        // Don't scale up past the original, but always include the smallest sizes.
        let sizes = candidates.filter { $0 <= max(longest, 32) }
        let destination = try makeDestination(output, format, count: sizes.count)
        for size in sizes {
            CGImageDestinationAddImage(destination, square(image, size: size), nil)
        }
        try finalize(destination, output)
    }

    private static func square(_ image: CGImage, size: Int) -> CGImage {
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        let scale = CGFloat(size) / CGFloat(max(image.width, image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(size) - width) / 2, y: (CGFloat(size) - height) / 2, width: width, height: height))
        return context.makeImage() ?? image
    }

    // MARK: Animation

    /// Copies every frame with its timing, so GIF ⇄ APNG stays animated.
    private static func copyAnimation(_ source: URL, to format: FileFormat, output: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ConversionError.unreadable(source.lastPathComponent)
        }
        let count = CGImageSourceGetCount(imageSource)
        let destination = try makeDestination(output, format, count: count)
        let toGIF = format == .gif
        let loop: [CFString: Any] = toGIF
            ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
            : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)

        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(imageSource, index, nil) else { continue }
            let delay = frameDelay(imageSource, index)
            let properties: [CFString: Any] = toGIF
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]]
            CGImageDestinationAddImage(destination, frame, properties as CFDictionary)
        }
        try finalize(destination, output)
    }

    private static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime]
            ?? png?[kCGImagePropertyAPNGUnclampedDelayTime] ?? png?[kCGImagePropertyAPNGDelayTime]) as? Double
        // Browsers treat near-zero delays as 0.1 s, so do the same.
        guard let delay, delay >= 0.02 else { return 0.1 }
        return delay
    }

    // MARK: SVG

    /// Rasterises at twice the SVG's own size, so it stays sharp on Retina screens.
    private static func renderSVG(_ url: URL) throws -> CGImage {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        let width = Int(image.size.width * 2)
        let height = Int(image.size.height * 2)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ConversionError.exportFailed("couldn't render \(url.lastPathComponent)") }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = nil
        guard let result = context.makeImage() else {
            throw ConversionError.exportFailed("couldn't render \(url.lastPathComponent)")
        }
        return result
    }

    /// Draws the SVG into a PDF page, so it stays vector.
    private static func writeVectorPDF(svg url: URL, to output: URL) throws {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        var page = CGRect(origin: .zero, size: image.size)
        guard let context = CGContext(output as CFURL, mediaBox: &page, nil) else {
            throw ConversionError.exportFailed("couldn't create PDF")
        }
        context.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: page)
        NSGraphicsContext.current = nil
        context.endPDFPage()
        context.closePDF()
    }

    // MARK: Image → PDF

    private static func writePDF(image: CGImage, dpi: CGFloat, to output: URL) throws {
        var page = CGRect(x: 0, y: 0, width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
        guard let context = CGContext(output as CFURL, mediaBox: &page, nil) else {
            throw ConversionError.exportFailed("couldn't create PDF")
        }
        context.beginPDFPage(nil)
        context.draw(image, in: page)
        context.endPDFPage()
        context.closePDF()
    }

    private static func dpi(of url: URL) -> CGFloat {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = properties[kCGImagePropertyDPIWidth] as? CGFloat, dpi > 0 else { return 72 }
        return dpi
    }

    // MARK: PDF → image

    /// Renders the first page at 2× (144 dpi) on white.
    private static func renderFirstPage(of url: URL) throws -> CGImage {
        // Keep the document alive while its page draws.
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        var size = page.bounds(for: .mediaBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let thumbnail = page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .mediaBox)
        guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ConversionError.exportFailed("couldn't render \(url.lastPathComponent)")
        }
        return image
    }

    // MARK: Helpers

    private static func orientedImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        return try orientedImage(from: source, index: largestImageIndex(source))
    }

    /// Icons hold several sizes and the first isn't always the biggest.
    private static func largestImageIndex(_ source: CGImageSource) -> Int {
        let count = CGImageSourceGetCount(source)
        guard count > 1, let type = CGImageSourceGetType(source) as String?,
              type == "com.microsoft.ico" || type == "com.apple.icns" else { return 0 }
        return (0..<count).max { pixelWidth(source, $0) < pixelWidth(source, $1) } ?? 0
    }

    private static func pixelWidth(_ source: CGImageSource, _ index: Int) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    }

    /// The full-size frame with EXIF orientation applied to the pixels.
    private static func orientedImage(from source: CGImageSource, index: Int) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw ConversionError.unreadable("image")
        }
        return image
    }

    private static func flattenedOnWhite(_ image: CGImage) -> CGImage {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(.white)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }
}

private extension FileFormat {
    var supportsAlpha: Bool {
        ![.jpg, .bmp].contains(self)
    }
}
