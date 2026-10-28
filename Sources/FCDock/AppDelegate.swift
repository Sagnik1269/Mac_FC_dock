import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let accessibilityItem = NSMenuItem(title: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let monitor = ShiftHoldMonitor()
    private let wheel = WheelController()
    private var pendingFiles: [URL] = []
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        monitor.onHoldBegan = { [weak self] in self?.holdBegan() }
        monitor.onCancel = { [weak self] in self?.wheel.hide() }
        wheel.onChoose = { [weak self] format in self?.chose(format) }

        startWhenTrusted()
    }

    // MARK: Gesture

    private func holdBegan() {
        // Holding Shift again while the wheel waits for a click leaves it where it is.
        guard !wheel.isVisible, FinderSelection.isFinderFrontmost else { return }

        let files: [URL]
        do {
            files = try FinderSelection.selectedFiles()
        } catch {
            Toast.shared.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", duration: 4)
            return
        }
        guard !files.isEmpty else { return }

        let formats = Converter.targets(for: files)
        guard !formats.isEmpty else {
            Toast.shared.show("FC Dock can't convert this file type yet", symbol: "questionmark.circle.fill")
            return
        }

        pendingFiles = files
        wheel.show(options: formats, files: files, at: NSEvent.mouseLocation)
    }

    private func chose(_ format: FileFormat) {
        let files = pendingFiles.filter { FileFormat.detect($0) != format }
        pendingFiles = []
        guard !files.isEmpty else { return }

        Task { @MainActor in
            await convert(files, to: format)
        }
    }

    @MainActor
    private func convert(_ files: [URL], to format: FileFormat) async {
        Toast.shared.show("Converting to \(format.label)…", symbol: "arrow.triangle.2.circlepath", duration: 120)

        var saved: [URL] = []
        var failures: [String] = []
        for file in files {
            do {
                saved.append(try await Converter.convert(file, to: format))
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        if let failure = failures.first {
            let prefix = saved.isEmpty ? "" : "Saved \(saved.count), "
            Toast.shared.show(prefix + failure, symbol: "xmark.octagon.fill", duration: 4)
        } else if saved.count == 1 {
            Toast.shared.show("Saved \(saved[0].lastPathComponent)")
        } else {
            Toast.shared.show("Saved \(saved.count) \(format.label) files")
        }
    }

    // MARK: Permissions

    private func startWhenTrusted() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            monitor.start()
            return
        }
        // Global key monitors only deliver events once Accessibility is granted, so wait for it.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.monitor.start()
            Toast.shared.show("FC Dock is ready. Hold ⇧ on a file in Finder, then click a format.", symbol: "circle.circle")
        }
    }

    @objc private func openDashboard() {
        DashboardController.shared.show()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "FC Dock")

        let menu = NSMenu()
        menu.delegate = self
        let hint = NSMenuItem(title: "Select a file in Finder, hold ⇧, then click a format", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        let dashboard = NSMenuItem(title: "Dashboard…", action: #selector(openDashboard), keyEquivalent: ",")
        dashboard.target = self
        menu.addItem(dashboard)
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit FC Dock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        accessibilityItem.title = AXIsProcessTrusted()
            ? "Accessibility: allowed"
            : "Accessibility: not allowed — Open Settings…"
    }
}
