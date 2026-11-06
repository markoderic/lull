import Foundation

/// Runs background work one job at a time at low priority, so imports never fight each other.
@MainActor
public final class JobQueue {
    public typealias Work = @MainActor () async -> Void

    private struct Job {
        let id: UUID
        let onCancelledBeforeStart: (@MainActor () -> Void)?
        let work: Work
    }

    private var pending: [Job] = []
    private var running: (id: UUID, task: Task<Void, Never>)?

    public init() {}

    /// `id` is the wallpaper the job belongs to, which is how it gets cancelled later.
    public func enqueue(id: UUID, onCancelledBeforeStart: (@MainActor () -> Void)? = nil, _ work: @escaping Work) {
        pending.append(Job(id: id, onCancelledBeforeStart: onCancelledBeforeStart, work: work))
        startNextIfIdle()
    }

    /// Cancels everything queued or running for a wallpaper. Running work sees normal task cancellation.
    public func cancel(id: UUID) {
        let cancelled = pending.filter { $0.id == id }
        pending.removeAll { $0.id == id }
        cancelled.forEach { $0.onCancelledBeforeStart?() }
        if running?.id == id { running?.task.cancel() }
    }

    public func hasJob(id: UUID) -> Bool {
        running?.id == id || pending.contains { $0.id == id }
    }

    private func startNextIfIdle() {
        guard running == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        let task = Task(priority: .utility) { @MainActor [weak self] in
            await job.work()
            self?.running = nil
            self?.startNextIfIdle()
        }
        running = (job.id, task)
    }
}
