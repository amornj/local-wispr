import AppKit
import CoreGraphics

// Listen-only: Fn keeps its normal macOS behavior. It never swallows other keys.
@MainActor
final class FnKeyMonitor {
    var onChange: ((Bool) -> Void)?
    var onAvailabilityChange: ((Bool) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastDown = false
    private var watchdog: Timer?

    var hasPermission: Bool { CGPreflightListenEventAccess() }

    @discardableResult
    func start(requestPermission: Bool) -> Bool {
        if tap != nil { return true }
        if !hasPermission {
            if requestPermission { _ = CGRequestListenEventAccess() }
            guard hasPermission else { onAvailabilityChange?(false); return false }
        }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if type == .flagsChanged {
                    monitor.update(down: event.flags.contains(.maskSecondaryFn))
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                               options: .listenOnly, eventsOfInterest: CGEventMask(1) << CGEventType.flagsChanged.rawValue,
                                               callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            onAvailabilityChange?(false)
            return false
        }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Recover a missed release (for example after a display or focus change).
                guard let self, self.lastDown else { return }
                if !CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn) { self.update(down: false) }
            }
        }
        onAvailabilityChange?(true)
        return true
    }

    private func update(down: Bool) {
        guard down != lastDown else { return }
        lastDown = down
        onChange?(down)
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil; lastDown = false
        onAvailabilityChange?(false)
    }
}
