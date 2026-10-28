import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The settings window: sliders for the wheel's size, glass and motion, with a live preview.
/// Edits go into a draft that only the preview uses; Save Changes applies it to the real wheel.
final class DashboardController: NSObject, NSWindowDelegate {
    static let shared = DashboardController()

    private var window: NSWindow?
    private let draft = Settings.shared.draft()

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "FC Dock"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: DashboardView(draft: draft))
            window.center()
            self.window = window
        }
        // A menu-bar app has to activate itself, or the window opens behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing with unsaved changes asks whether to keep them, like a document would.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !draft.matches(.shared) else { return true }
        let alert = NSAlert()
        alert.messageText = "Save your changes to the wheel?"
        alert.informativeText = "If you don't save, the wheel keeps its current look."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Settings.shared.copy(from: draft)
            return true
        case .alertSecondButtonReturn:
            draft.copy(from: .shared)
            return true
        default:
            return false
        }
    }
}

/// The preview's wheel, with its own open animation and hover tracking.
private final class PreviewState: ObservableObject {
    enum Sample: String, CaseIterable, Identifiable {
        case document = "Document", image = "Image", audio = "Audio"
        var id: Self { self }

        var formats: [FileFormat] {
            switch self {
            case .document: return Converter.targets(from: .docx)
            case .image: return Converter.targets(from: .png)
            case .audio: return Converter.targets(from: .mp3)
            }
        }

        var cover: NSImage {
            let type: UTType = self == .document ? .pdf : self == .image ? .png : .mp3
            return NSWorkspace.shared.icon(for: type)
        }
    }

    let model = WheelModel()
    /// The real overlay, for checking the glass against whatever is on screen. It shows the draft.
    let onScreen: WheelController
    private var onScreenHide: DispatchWorkItem?
    private var generation = 0

    @Published var sample: Sample = .document {
        didSet { load() }
    }

    init(settings: Settings) {
        onScreen = WheelController(settings: settings)
        load()
    }

    func load() {
        model.options = sample.formats
        model.cover = sample.cover
        model.coverAlignment = .center
        model.selected = nil
        replay()
    }

    /// Runs the same page → circle → arcs sequence as the real wheel.
    func replay() {
        generation += 1
        let current = generation
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.phase = .hidden }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.generation == current else { return }
            self.model.phase = .page
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.21) { [weak self] in
            guard let self, self.generation == current else { return }
            self.model.phase = .ring
        }
    }

    func hover(at location: CGPoint?, metrics: WheelMetrics) {
        let selection = location.flatMap { point in
            metrics.index(
                dx: point.x - metrics.panelSize / 2,
                dy: metrics.panelSize / 2 - point.y,
                count: model.options.count
            )
        }
        if selection != model.selected { model.selected = selection }
    }

    /// Opens the real wheel in the middle of the screen for a few seconds; it follows the mouse like the real thing.
    func showOnScreen() {
        guard let screen = NSScreen.main else { return }
        onScreen.show(
            options: sample.formats,
            files: [],
            cover: sample.cover,
            at: CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        )
        onScreenHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onScreen.hide() }
        onScreenHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}

private enum PreviewBackground: String, CaseIterable, Identifiable {
    case colourful = "Colourful", light = "Light", dark = "Dark"
    var id: Self { self }

    @ViewBuilder var view: some View {
        switch self {
        case .colourful:
            LinearGradient(
                colors: [Color(red: 0.98, green: 0.45, blue: 0.35), Color(red: 0.95, green: 0.8, blue: 0.3),
                         Color(red: 0.3, green: 0.75, blue: 0.6), Color(red: 0.3, green: 0.45, blue: 0.95)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .light: Color(white: 0.95)
        case .dark: Color(white: 0.12)
        }
    }
}

private struct DashboardView: View {
    /// The unsaved copy the sliders edit.
    @ObservedObject private var settings: Settings
    @ObservedObject private var saved = Settings.shared
    @StateObject private var preview: PreviewState
    @State private var background: PreviewBackground = .colourful

    private static let previewSize: CGFloat = 400

    init(draft: Settings) {
        settings = draft
        _preview = StateObject(wrappedValue: PreviewState(settings: draft))
    }

    private var hasChanges: Bool { !settings.matches(saved) }

    var body: some View {
        TabView {
            HStack(spacing: 0) {
                previewPane
                Divider()
                controls
            }
            .tabItem { Label("Wheel", systemImage: "circle.circle") }
            ToolsView()
                .tabItem { Label("Formats", systemImage: "square.stack.3d.up") }
        }
        .padding(.top, 8)
        .frame(width: 780, height: 540)
    }

    // MARK: Preview

    private var previewPane: some View {
        let metrics = WheelMetrics(settings, fit: Self.previewSize)
        return VStack(spacing: 12) {
            ZStack {
                background.view
                WheelView(model: preview.model, settings: settings, fit: Self.previewSize)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): preview.hover(at: location, metrics: metrics)
                        case .ended: preview.hover(at: nil, metrics: metrics)
                        }
                    }
            }
            .frame(width: Self.previewSize, height: Self.previewSize)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if metrics.scale < CGFloat(settings.wheelScale) - 0.001 {
                    Text("Scaled to fit")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                        .padding(8)
                }
            }

            HStack {
                Picker("Sample", selection: $preview.sample) {
                    ForEach(PreviewState.Sample.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                Picker("Background", selection: $background) {
                    ForEach(PreviewBackground.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                Spacer()
                Button {
                    preview.replay()
                } label: {
                    Image(systemName: "play.fill")
                }
                .help("Replay the opening animation")
                Button("Show on Screen") { preview.showOnScreen() }
                    .help("Opens the wheel in the middle of the screen for 6 seconds, with your unsaved changes")
            }
            .frame(width: Self.previewSize)
        }
        .padding(20)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Size") {
                    SettingSlider(title: "Wheel size", value: $settings.wheelScale, option: Settings.Options.wheelScale, format: .percent)
                    SettingSlider(title: "Cover size", value: $settings.coverScale, option: Settings.Options.coverScale, format: .percent)
                }
                Section("Glass") {
                    SettingSlider(title: "Frost", value: $settings.blur, option: Settings.Options.blur, format: .percent)
                    SettingSlider(title: "Dark tint", value: $settings.tint, option: Settings.Options.tint, format: .percent)
                    SettingSlider(title: "Hover colour", value: $settings.highlight, option: Settings.Options.highlight, format: .percent)
                }
                Section("Arcs") {
                    SettingSlider(title: "Gap", value: $settings.arcGap, option: Settings.Options.arcGap, format: .points)
                    SettingSlider(title: "Hover pop", value: $settings.popDistance, option: Settings.Options.popDistance, format: .points)
                }
                Section("Gesture") {
                    SettingSlider(title: "Hold ⇧ for", value: $settings.holdDelay, option: Settings.Options.holdDelay, format: .seconds)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Reset to Defaults") { settings.resetToDefaults() }
                    .help("Puts every slider back to its original value; save to apply it")
                Spacer()
                if hasChanges {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Revert") { settings.copy(from: saved) }
                    .disabled(!hasChanges)
                    .help("Go back to the saved look")
                Button("Save Changes") { saved.copy(from: settings) }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
                    .help("Apply these settings to the real wheel (⌘S)")
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SettingSlider: View {
    enum Format { case percent, points, seconds }

    let title: String
    @Binding var value: Double
    let option: Settings.Option
    let format: Format

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(formatted)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: option.range)
                .labelsHidden()
        }
        .contextMenu {
            Button("Reset \(title)") { value = option.defaultValue }
        }
    }

    private var formatted: String {
        switch format {
        case .percent: return "\(Int((value * 100).rounded()))%"
        case .points: return String(format: "%.1f pt", value)
        case .seconds: return String(format: "%.2f s", value)
        }
    }
}

// MARK: - Formats

/// Which helper tools are installed, what each unlocks, and how to install the missing ones.
private struct ToolsView: View {
    @State private var installed: Set<String> = []
    @State private var coverage: (available: Int, total: Int)?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conversion tools").font(.headline)
                    Text("Formats only appear on the wheel when something on this Mac can make them. Install a tool with Homebrew, then check again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let coverage {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(coverage.available) of \(coverage.total)").font(.title3.weight(.semibold)).monospacedDigit()
                        Text("conversions available").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            List(Tool.all) { tool in
                row(tool)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                Text("Built into macOS: documents via the text system, images via ImageIO, audio via Core Audio, MIDI, data formats, subtitles, archives and SQLite.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check Again") { refresh() }
            }
        }
        .padding(20)
        .onAppear(perform: refresh)
    }

    private func row(_ tool: Tool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: installed.contains(tool.id) ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3)
                .foregroundStyle(installed.contains(tool.id) ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(.body.weight(.medium))
                Text(tool.purpose).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if installed.contains(tool.id) {
                Text("Installed").font(.caption).foregroundStyle(.secondary)
            } else if let command = tool.install {
                Text(command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Button(copied == tool.id ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = tool.id
                }
            } else {
                Button("App Store") {
                    NSWorkspace.shared.open(URL(string: "macappstore://search.itunes.apple.com/WebObjects/MZSearch.woa/wa/search?q=\(tool.name)")!)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func refresh() {
        installed = Set(Tool.all.filter(\.isInstalled).map(\.id))
        coverage = nil
        // Planning every catalog route takes a moment, so it runs off the main thread.
        Task.detached(priority: .userInitiated) {
            let available = Converter.availableEngines()
            var count = 0
            var total = 0
            for (source, targets) in Catalog.menu {
                total += targets.count
                count += targets.filter { !Converter.routes(from: source, to: $0, using: available).isEmpty }.count
            }
            await MainActor.run { coverage = (count, total) }
        }
    }
}
