import Foundation
import Testing
@testable import LullCore

@MainActor
@Suite("Job queue")
struct JobQueueTests {
    /// Lets a test hold a job open and release it at a chosen moment.
    final class Gate: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        private let lock = NSLock()

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock(); defer { lock.unlock() }
                if opened { c.resume() } else { continuation = c }
            }
        }

        func open() {
            lock.lock(); defer { lock.unlock() }
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @Test func jobsRunOneAtATimeInOrder() async {
        let queue = JobQueue()
        let gate = Gate()
        var log: [String] = []
        queue.enqueue(id: UUID()) { log.append("a start"); await gate.wait(); log.append("a end") }
        queue.enqueue(id: UUID()) { log.append("b") }
        await waitUntil { log.contains("a start") }
        #expect(log == ["a start"])
        gate.open()
        await waitUntil { log.count == 3 }
        #expect(log == ["a start", "a end", "b"])
    }

    @Test func cancellingAPendingJobMeansItNeverRuns() async {
        let queue = JobQueue()
        let gate = Gate()
        let pendingID = UUID()
        var log: [String] = []
        var cancelled = false
        queue.enqueue(id: UUID()) { await gate.wait(); log.append("a") }
        queue.enqueue(id: pendingID, onCancelledBeforeStart: { cancelled = true }) { log.append("b") }

        queue.cancel(id: pendingID)
        gate.open()
        await waitUntil { log.contains("a") }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(log == ["a"])
        #expect(cancelled)
    }

    @Test func cancellingARunningJobCancelsItsTask() async {
        let queue = JobQueue()
        let id = UUID()
        var sawCancellation = false
        var started = false
        queue.enqueue(id: id) {
            started = true
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                sawCancellation = error is CancellationError
            }
        }
        await waitUntil { started }
        queue.cancel(id: id)
        await waitUntil { sawCancellation }
        #expect(sawCancellation)
    }

    @Test func aCancelledJobLetsTheNextOneRun() async {
        let queue = JobQueue()
        let id = UUID()
        var started = false, nextRan = false
        queue.enqueue(id: id) {
            started = true
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        queue.enqueue(id: UUID()) { nextRan = true }
        await waitUntil { started }
        queue.cancel(id: id)
        await waitUntil { nextRan }
        #expect(nextRan)
    }

    @Test func reportsWhetherAWallpaperHasWork() async {
        let queue = JobQueue()
        let gate = Gate()
        let id = UUID()
        var done = false
        queue.enqueue(id: id) { await gate.wait(); done = true }
        #expect(queue.hasJob(id: id))
        gate.open()
        await waitUntil { done }
        await waitUntil { !queue.hasJob(id: id) }
        #expect(!queue.hasJob(id: id))
    }
}

@Suite("App settings")
struct AppSettingsTests {
    private func makeSettings() -> AppSettings {
        let name = "lull-tests-\(UUID().uuidString)"
        return AppSettings(defaults: UserDefaults(suiteName: name)!)
    }

    @Test func desktopFocusIsTheDefaultRule() {
        #expect(makeSettings().pauseRule == .desktopFocus)
    }

    @Test func nothingIsCurrentByDefault() {
        #expect(makeSettings().currentWallpaperID == nil)
    }

    @Test func valuesPersist() {
        let name = "lull-tests-\(UUID().uuidString)"
        let id = UUID()
        let first = AppSettings(defaults: UserDefaults(suiteName: name)!)
        first.pauseRule = .wheneverVisible
        first.currentWallpaperID = id
        let second = AppSettings(defaults: UserDefaults(suiteName: name)!)
        #expect(second.pauseRule == .wheneverVisible)
        #expect(second.currentWallpaperID == id)
    }

    @Test func clearingCurrentWallpaperPersists() {
        let settings = makeSettings()
        settings.currentWallpaperID = UUID()
        settings.currentWallpaperID = nil
        #expect(settings.currentWallpaperID == nil)
    }

    @Test func unknownStoredRuleFallsBackToDefault() {
        let defaults = UserDefaults(suiteName: "lull-tests-\(UUID().uuidString)")!
        defaults.set("somethingElse", forKey: "pauseRule")
        #expect(AppSettings(defaults: defaults).pauseRule == .desktopFocus)
    }
}
