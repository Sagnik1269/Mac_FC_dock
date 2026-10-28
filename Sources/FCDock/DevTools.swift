import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Renders the wheel's key frames to PNGs so the layout can be checked without the gesture:
///   FCDock --render-wheel <file> <output-folder>
enum DevTools {
    @MainActor
    static func renderWheel(for file: URL, into folder: URL) async throws {
        let model = WheelModel()
        model.options = Converter.targets(for: [file])
        model.cover = await thumbnail(for: file) ?? NSWorkspace.shared.icon(forFile: file.path)

        let frames: [(String, WheelModel.Phase, Int?)] = [
            ("1-page", .page, nil),
            ("2-ring", .ring, nil),
            ("3-hover", .ring, 0),
        ]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, phase, selected) in frames {
            model.phase = phase
            model.selected = selected
            let renderer = ImageRenderer(content: WheelView(model: model).background(Color(white: 0.85)))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { continue }
            try png.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }

    /// Shows the real wheel in the middle of the screen and steps the highlight round it:
    ///   FCDock --demo-wheel <file> [seconds]
    @MainActor
    static func demoWheel(for file: URL, seconds: Double) {
        let wheel = WheelController()
        let options = Converter.targets(for: [file])
        guard let screen = NSScreen.main, !options.isEmpty else { exit(1) }
        wheel.show(options: options, files: [file], at: CGPoint(x: screen.frame.midX, y: screen.frame.midY), tracksMouse: false)

        for step in 0..<options.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9 + Double(step) * 0.45) { wheel.select(step) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9 + Double(options.count) * 0.45) { wheel.select(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        DevTools.demoController = wheel
    }

    @MainActor private static var demoController: WheelController?

    private static func thumbnail(for file: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: file, size: CGSize(width: 180, height: 240), scale: 2, representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
