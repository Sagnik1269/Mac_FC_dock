import AppKit

/// Watches for Shift being held on its own (no other keys, modifiers or clicks) for `holdDelay`.
/// Global event monitoring needs the Accessibility permission.
final class ShiftHoldMonitor {
    var holdDelay: TimeInterval { Settings.shared.holdDelay }

    /// Shift has been held long enough. Releasing it afterwards does nothing; the wheel waits for a click.
    var onHoldBegan: (() -> Void)?
    /// Another modifier joined Shift after `onHoldBegan`.
    var onCancel: (() -> Void)?

    private var monitors: [Any] = []
    private var pending: Timer?
    private var fired = false

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
        }
        let interrupts = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.interrupt()
        }
        monitors = [flags, interrupts].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        reset()
    }

    private func handleFlags(_ event: NSEvent) {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        if modifiers == .shift {
            guard pending == nil, !fired else { return }
            pending = Timer.scheduledTimer(withTimeInterval: holdDelay, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.pending = nil
                self.fired = true
                self.onHoldBegan?()
            }
            return
        }

        let wasFired = fired
        reset()
        if wasFired, !modifiers.isEmpty { onCancel?() }
    }

    // Typing capitals or Shift-clicking cancels a pending hold. Once the wheel is open it handles
    // clicks and keys itself.
    private func interrupt() {
        reset()
    }

    private func reset() {
        pending?.invalidate()
        pending = nil
        fired = false
    }
}
