import AppKit
import Combine
import QuickLookThumbnailing
import SwiftUI

final class WheelModel: ObservableObject {
    /// hidden → page (the document pops out) → ring (it turns into a circle and the arcs pop in).
    enum Phase { case hidden, page, ring }

    @Published var options: [FileFormat] = []
    @Published var selected: Int?
    @Published var cover: NSImage?
    @Published var fileCount = 1
    // Documents show the top of the first page; images are centred.
    @Published var coverAlignment: Alignment = .top
    @Published var phase: Phase = .hidden
}

/// Sizes for one wheel, derived from the user's settings. The v1 design is the 100% case.
struct WheelMetrics {
    let panelSize: CGFloat
    let outerRadius: CGFloat
    let innerRadius: CGFloat
    let coverDiameter: CGFloat
    let arcGap: CGFloat
    let popDistance: CGFloat
    let popGrowth: CGFloat
    let deadZone: CGFloat
    /// Multiplier for fonts, corner radii and shadows.
    let scale: CGFloat
    let blur: Double
    let tint: Double
    let highlight: Double

    /// `fit` shrinks the whole layout to fit a preview of that width, keeping its proportions.
    init(_ settings: Settings, fit: CGFloat? = nil) {
        let wheel = CGFloat(settings.wheelScale)
        let pop = CGFloat(settings.popDistance)
        // Leave room around the ring for the hovered arc's pop and growth.
        let naturalPanel = 2 * (128 * wheel + pop * 2.25 + 23)
        let shrink = fit.map { min(1, $0 / naturalPanel) } ?? 1

        scale = wheel * shrink
        panelSize = naturalPanel * shrink
        outerRadius = 128 * scale
        innerRadius = 60 * scale
        coverDiameter = 100 * scale * CGFloat(settings.coverScale)
        arcGap = CGFloat(settings.arcGap) * shrink
        popDistance = pop * shrink
        popGrowth = pop * 1.25 * shrink
        deadZone = 24 * scale
        blur = settings.blur
        tint = settings.tint
        highlight = settings.highlight
    }

    /// The arc a pointer offset from the centre is over, or nil in the centre or outside the ring.
    /// `dy` is positive upwards.
    func index(dx: CGFloat, dy: CGFloat, count: Int) -> Int? {
        let distance = hypot(dx, dy)
        // A little slack past the edge so a click right on the rim still counts.
        guard count > 0, distance >= deadZone, distance <= outerRadius + popGrowth + popDistance + 12 * scale else { return nil }
        // 0 radians points straight up, increasing clockwise — same layout as ArcSegment.
        var angle = atan2(dx, dy)
        if angle < 0 { angle += 2 * .pi }
        return Int((angle / (2 * .pi / Double(count))).rounded()) % count
    }
}

/// Shows the donut menu centred on the cursor, highlights the arc under the cursor, and reports
/// the format the user clicks. Any click elsewhere, or a key press, closes it.
final class WheelController {
    /// Called with the clicked format, after the wheel has started closing.
    var onChoose: ((FileFormat) -> Void)?

    private let model = WheelModel()
    private var center: CGPoint = .zero
    private var tracker: Timer?
    // Bumped on every show/hide so stale animation steps and thumbnails are ignored.
    private var generation = 0

    private var settingsObserver: AnyCancellable?
    private var eventMonitors: [Any] = []

    private lazy var panel: NSPanel = {
        let size = metrics.panelSize
        let panel = OverlayPanel(size: NSSize(width: size, height: size))
        panel.contentView = NSHostingView(rootView: WheelView(model: model, settings: settings))
        return panel
    }()

    /// The saved settings for the real wheel; the dashboard's on-screen preview passes its draft.
    private let settings: Settings
    private var metrics: WheelMetrics { WheelMetrics(settings) }

    init(settings: Settings = .shared) {
        self.settings = settings
        // Keep an open wheel centred while its size is being changed from the dashboard.
        settingsObserver = settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.placePanel() }
        }
    }

    private func placePanel() {
        let size = metrics.panelSize
        panel.setFrame(NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size), display: true)
    }

    var isVisible: Bool { tracker != nil }

    /// `cover` is used when there are no files (the dashboard's on-screen preview).
    func show(options: [FileFormat], files: [URL], cover: NSImage? = nil, at point: NSPoint, tracksMouse: Bool = true) {
        generation += 1
        let current = generation

        withoutAnimation {
            model.options = options
            model.selected = nil
            model.fileCount = max(files.count, 1)
            model.coverAlignment = files.first.flatMap { FileFormat.detect($0) }.map { $0.isImage || $0.isAudio } == true ? .center : .top
            model.cover = files.first.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? cover
            model.phase = .hidden
        }
        if let first = files.first { loadCover(for: first, generation: current) }

        center = point
        placePanel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // Let the hidden state render first so the pop-out animates from it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self, self.generation == current else { return }
            self.model.phase = .page
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
            guard let self, self.generation == current else { return }
            self.model.phase = .ring
        }

        tracker?.invalidate()
        guard tracksMouse else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.track() }
        RunLoop.main.add(timer, forMode: .common)
        tracker = timer
        watchClicks()
    }

    /// The panel takes clicks while open, so choosing an arc doesn't also click (and deselect) in Finder.
    private func watchClicks() {
        removeEventMonitors()
        panel.ignoresMouseEvents = false
        // Clicks on the wheel reach this app even though Finder stays frontmost.
        let onWheel = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            self.clicked(event.type == .leftMouseDown)
            return nil
        }
        // Clicks anywhere else, and key presses (Finder is still frontmost), dismiss it.
        let elsewhere = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] _ in
            self?.hide()
        }
        eventMonitors = [onWheel, elsewhere].compactMap { $0 }
    }

    private func removeEventMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors = []
    }

    /// A left click on an arc picks it; the centre, the corners or a right click just close the wheel.
    private func clicked(_ isLeftClick: Bool) {
        let mouse = NSEvent.mouseLocation
        let index = metrics.index(dx: mouse.x - center.x, dy: mouse.y - center.y, count: model.options.count)
        let format = isLeftClick ? index.map { model.options[$0] } : nil
        hide()
        if let format { onChoose?(format) }
    }

    func hide() {
        generation += 1
        let current = generation
        tracker?.invalidate()
        tracker = nil
        removeEventMonitors()
        panel.ignoresMouseEvents = true

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
            self.withoutAnimation {
                self.model.phase = .hidden
                self.model.selected = nil
            }
        })
    }

    /// Highlights an arc directly (used by the demo hook instead of the mouse).
    func select(_ index: Int?) {
        model.selected = index
    }

    private func track() {
        let mouse = NSEvent.mouseLocation
        let newSelection = metrics.index(dx: mouse.x - center.x, dy: mouse.y - center.y, count: model.options.count)
        guard newSelection != model.selected else { return }
        model.selected = newSelection
        if newSelection != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// Swaps the file icon for a Quick Look render of the first page once it's ready.
    private func loadCover(for file: URL, generation current: Int) {
        let request = QLThumbnailGenerator.Request(
            fileAt: file,
            size: CGSize(width: 180, height: 240),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let image = thumbnail?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.withoutAnimation { self.model.cover = image }
            }
        }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }
}

/// A borderless panel that floats above everything without stealing focus from Finder.
/// Click-through unless the wheel turns clicks on while it's open.
final class OverlayPanel: NSPanel {
    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel
    @ObservedObject var settings: Settings = .shared
    /// Shrinks the wheel to fit this width (the dashboard preview). Nil draws it at its real size.
    var fit: CGFloat?

    var body: some View {
        let metrics = WheelMetrics(settings, fit: fit)
        ZStack {
            ForEach(Array(model.options.enumerated()), id: \.element) { index, format in
                ArcSegment(
                    format: format,
                    index: index,
                    count: model.options.count,
                    highlighted: model.selected == index,
                    revealed: model.phase == .ring,
                    metrics: metrics
                )
                .zIndex(model.selected == index ? 1 : 0)
            }
            CoverView(
                image: model.cover,
                alignment: model.coverAlignment,
                fileCount: model.fileCount,
                phase: model.phase,
                metrics: metrics
            )
            .zIndex(2)
        }
        .frame(width: metrics.panelSize, height: metrics.panelSize)
        .environment(\.colorScheme, .dark)
    }
}

/// One format's slice of the donut, in frosted glass. Pops outward when highlighted.
private struct ArcSegment: View {
    let format: FileFormat
    let index: Int
    let count: Int
    let highlighted: Bool
    let revealed: Bool
    let metrics: WheelMetrics

    var body: some View {
        let step = 2 * Double.pi / Double(count)
        let mid = Double(index) * step
        // The glass is a real blur view, which ignores scaleEffect, so growth is animated through the radii.
        let collapse: CGFloat = revealed ? 1 : 0.4
        let innerRadius = metrics.innerRadius * collapse
        let outerRadius = (metrics.outerRadius + (highlighted ? metrics.popGrowth : 0)) * collapse
        let shape = RingSegment(
            startAngle: mid - step / 2,
            endAngle: mid + step / 2,
            halfGap: metrics.arcGap / 2,
            innerRadius: innerRadius,
            outerRadius: outerRadius
        )
        let labelRadius = (innerRadius + outerRadius) / 2
        let pop = highlighted ? metrics.popDistance : 0
        let sheen = LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom)
        let rim = LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.15)], startPoint: .top, endPoint: .bottom)

        ZStack {
            // A light, half-transparent blur so background colours come through,
            // plus a faint dark tint to keep the white labels readable on bright backgrounds.
            VisualEffectBackground(material: .hudWindow, opacity: metrics.blur)
                .clipShape(shape)
            shape.fill(Color.black.opacity(metrics.tint))
            shape.fill(sheen)
            shape.fill(Color.accentColor.opacity(highlighted ? metrics.highlight : 0))
            shape.stroke(rim, lineWidth: highlighted ? 1.5 : 1)
            VStack(spacing: 3 * metrics.scale) {
                Image(systemName: format.symbol)
                    .font(.system(size: 17 * metrics.scale, weight: .medium))
                Text(format.label)
                    .font(.system(size: 10.5 * metrics.scale, weight: .bold, design: .rounded))
            }
            .foregroundStyle(Color.white.opacity(highlighted ? 1 : 0.92))
            .shadow(color: .black.opacity(0.6), radius: 3)
            .scaleEffect(revealed ? 1 : 0.5)
            .offset(x: sin(mid) * labelRadius, y: -cos(mid) * labelRadius)
        }
        .frame(width: metrics.panelSize, height: metrics.panelSize)
        .offset(x: sin(mid) * pop, y: -cos(mid) * pop)
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: highlighted)
        // Pop in from the centre one after another, clockwise from the top.
        .opacity(revealed ? 1 : 0)
        .animation(
            revealed ? .spring(response: 0.34, dampingFraction: 0.62).delay(Double(index) * 0.04) : nil,
            value: revealed
        )
    }
}

/// An annular sector whose straight edges sit `halfGap` back from the radial boundary lines,
/// so neighbouring segments are separated by a gap of constant width rather than a wedge.
/// Angles are in radians, 0 = straight up, increasing clockwise.
private struct RingSegment: Shape {
    var startAngle: Double
    var endAngle: Double
    var halfGap: CGFloat
    var innerRadius: CGFloat
    var outerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(innerRadius, outerRadius) }
        set {
            innerRadius = newValue.first
            outerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // A point at radius r and angle boundary + asin(h / r) is exactly h from the boundary line,
        // so the edge joining the inner and outer arcs runs parallel to it.
        func trim(_ radius: CGFloat) -> Double { asin(Double(min(halfGap / max(radius, 1), 0.99))) }
        // SwiftUI measures from +x in a y-down space, where increasing angles already run clockwise.
        func angle(_ value: Double) -> Angle { .radians(value - .pi / 2) }

        var path = Path()
        path.addArc(center: center, radius: outerRadius,
                    startAngle: angle(startAngle + trim(outerRadius)), endAngle: angle(endAngle - trim(outerRadius)),
                    clockwise: false)
        path.addArc(center: center, radius: innerRadius,
                    startAngle: angle(endAngle - trim(innerRadius)), endAngle: angle(startAngle + trim(innerRadius)),
                    clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// The document's first page: pops out as a page, then morphs into a circle.
private struct CoverView: View {
    let image: NSImage?
    let alignment: Alignment
    let fileCount: Int
    let phase: WheelModel.Phase
    let metrics: WheelMetrics

    var body: some View {
        let diameter = metrics.coverDiameter
        let scale = metrics.scale
        let size: CGSize = {
            switch phase {
            case .hidden: return CGSize(width: diameter * 0.4, height: diameter * 0.53)
            case .page: return CGSize(width: diameter * 0.8, height: diameter * 1.06)
            case .ring: return CGSize(width: diameter, height: diameter)
            }
        }()
        let shape = RoundedRectangle(cornerRadius: phase == .ring ? diameter / 2 : 6 * scale, style: .circular)

        ZStack {
            Color.white
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height, alignment: alignment)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.5), lineWidth: 2))
        .shadow(color: .black.opacity(0.45), radius: 12 * scale, y: 5 * scale)
        .overlay(alignment: .bottom) {
            if fileCount > 1 {
                Text("+\(fileCount - 1)")
                    .font(.system(size: 11 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7 * scale)
                    .padding(.vertical, 3 * scale)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(y: 6 * scale)
            }
        }
        .opacity(phase == .hidden ? 0 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: phase)
    }
}
