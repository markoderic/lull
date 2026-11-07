import AppKit

/// Wakes the app for the next scheduled wallpaper change, with no checking in between.
///
/// Timers don't reliably count time while a Mac sleeps, so waking up and clock changes also count as
/// a reason to look again.
@MainActor
final class ScheduleTimer {
    private var timer: Timer?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private let onFire: () -> Void

    init(onFire: @escaping () -> Void) {
        self.onFire = onFire
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification)
        observe(NotificationCenter.default, .NSSystemClockDidChange)
        observe(NotificationCenter.default, .NSSystemTimeZoneDidChange)
    }

    /// Replaces any waiting timer. `nil` means nothing is scheduled.
    func arm(at date: Date?) {
        timer?.invalidate()
        timer = nil
        guard let date else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFire() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFire() }
        }
        observers.append((center, token))
    }
}
