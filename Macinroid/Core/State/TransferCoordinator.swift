import Foundation
import Observation

/// One copy operation, from the moment it is requested until it is over.
struct TransferJob: Identifiable, Equatable {
    enum Phase: Equatable {
        case waiting
        /// Looking for items that would be replaced.
        case preparing
        case counting
        case copying
        case cancelling
        case finished
        case cancelled
        case failed(DeviceError)

        var isOver: Bool {
            switch self {
            case .finished, .cancelled, .failed: true
            default: false
            }
        }
    }

    let id: UInt64
    var request: TransferRequest
    var deviceName: String
    /// What a download is headed for, when "Mac" is not specific enough.
    var targetName: String?
    var phase: Phase = .waiting

    var progress = TransferProgress()
    var countedFiles = 0
    var countedBytes: Int64 = 0

    /// Bytes per second, averaged over the last few seconds.
    var speed: Double = 0
    var startedAt: Date?
    var finishedAt: Date?

    var direction: TransferDirection { request.direction }

    /// "Copying to Pixel 9", "Copying to Mac"
    var title: String {
        let target = direction == .upload ? deviceName : targetName ?? "Mac"
        return switch phase {
        case .waiting: "Waiting to copy to \(target)"
        case .preparing, .counting: "Preparing to copy to \(target)"
        case .copying: "Copying to \(target)"
        case .cancelling: "Stopping…"
        case .finished: "Copied to \(target)"
        case .cancelled: "Copy to \(target) cancelled"
        case .failed: "Couldn’t copy to \(target)"
        }
    }

    /// Seconds left, when the total size is known and the rate has settled.
    var remaining: TimeInterval? {
        guard phase == .copying, progress.bytesTotal > 0, speed > 1 else { return nil }
        return Double(progress.bytesTotal - progress.bytesDone) / speed
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// "3 of 120 items" while copying, "120 items" once done.
    var itemsSummary: String {
        let done = progress.filesDone
        let total = progress.filesTotal
        if phase.isOver {
            return total > 0 && done < total ? "\(done.formatted()) of \(Format.items(total))" : Format.items(done)
        }
        return total > 0 ? "\(min(done + 1, total).formatted()) of \(Format.items(total))" : "Item \((done + 1).formatted())"
    }

    /// "1.2 GB of 4.5 GB" or "1.2 GB".
    var bytesSummary: String {
        progress.bytesTotal > 0
            ? "\(Format.bytes(progress.bytesDone)) of \(Format.bytes(progress.bytesTotal))"
            : Format.bytes(progress.bytesDone)
    }
}

/// Runs transfers one after the other and publishes their progress.
@MainActor
@Observable
final class TransferCoordinator {
    /// Decides, just before a job starts, what it copies. Returning nil
    /// calls the job off, as when the user declines to replace existing items.
    typealias Prepare = @MainActor (TransferRequest) async -> TransferRequest?

    private(set) var active: TransferJob?
    private(set) var waiting: [TransferJob] = []
    /// Jobs that are over, newest first.
    private(set) var recent: [TransferJob] = []

    /// Called once a job is over, before the next one starts.
    @ObservationIgnored var onJobEnded: (@MainActor (TransferJob) async -> Void)?
    /// Called before every job, to stop whatever else is using the connection.
    @ObservationIgnored var beforeEachJob: (@MainActor () async -> Void)?

    @ObservationIgnored private let backend: any DeviceBackend
    @ObservationIgnored private var prepareSteps: [UInt64: Prepare] = [:]
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var samples: [(time: Date, bytes: Int64)] = []

    init(backend: any DeviceBackend) {
        self.backend = backend
    }

    var isBusy: Bool { active != nil }
    var hasWork: Bool { active != nil || !waiting.isEmpty }

    // MARK: Queue

    func enqueue(_ request: TransferRequest, deviceName: String, targetName: String? = nil, prepare: Prepare? = nil) {
        waiting.append(TransferJob(id: request.id, request: request, deviceName: deviceName, targetName: targetName))
        prepareSteps[request.id] = prepare
        startNextIfIdle()
    }

    /// Stops the job: at once if it is waiting, as soon as the device allows if it is running.
    func cancel(_ id: UInt64) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            var job = waiting.remove(at: index)
            prepareSteps[id] = nil
            job.phase = .cancelled
            remember(job)
        } else if active?.id == id, active?.phase.isOver == false {
            active?.phase = .cancelling
            backend.cancelTransfer(id: id)
        }
    }

    func cancelAll() {
        for job in waiting { cancel(job.id) }
        if let active { cancel(active.id) }
    }

    func clearRecent() {
        recent.removeAll()
    }

    /// Resolves when no transfer is running or waiting any more.
    func waitUntilIdle() async {
        while hasWork {
            await runner?.value
            await Task.yield()
        }
    }

    private func startNextIfIdle() {
        guard runner == nil, !waiting.isEmpty else { return }
        runner = Task {
            while !waiting.isEmpty {
                await run(waiting.removeFirst())
            }
            runner = nil
        }
    }

    // MARK: Running a job

    private func run(_ job: TransferJob) async {
        var job = job
        job.startedAt = Date()
        job.phase = .preparing
        active = job
        samples = []

        await beforeEachJob?()

        if let prepare = prepareSteps.removeValue(forKey: job.id) {
            guard let request = await prepare(job.request) else {
                finish(.cancelled)
                await end()
                return
            }
            active?.request = request
        }

        guard let request = active?.request, active?.phase != .cancelling else {
            finish(.cancelled)
            await end()
            return
        }

        active?.phase = request.countFirst ? .counting : .copying
        active?.startedAt = Date()

        do {
            for try await event in backend.transfer(request) {
                apply(event)
            }
            finish(.finished)
        } catch {
            let error = DeviceError(error)
            finish(error.isCancellation ? .cancelled : .failed(error), error: error)
        }

        await end()
    }

    private func apply(_ event: TransferEvent) {
        guard var job = active else { return }

        switch event {
        case .counting(let files, let bytes, _):
            job.countedFiles = files
            job.countedBytes = bytes

        case .progress(let progress):
            if job.phase == .counting || job.phase == .preparing {
                job.phase = .copying
            }
            job.progress = progress
            job.speed = measureSpeed(bytesDone: progress.bytesDone)
        }

        active = job
    }

    /// The transfer rate over the last three seconds, which is steady enough to read.
    private func measureSpeed(bytesDone: Int64) -> Double {
        let now = Date()
        samples.append((now, bytesDone))
        samples.removeAll { now.timeIntervalSince($0.time) > 3 }

        guard let first = samples.first, now.timeIntervalSince(first.time) >= 0.4 else {
            return active?.speed ?? 0
        }
        return Double(bytesDone - first.bytes) / now.timeIntervalSince(first.time)
    }

    /// The error that ended the active job, for the code that cleans up after it.
    @ObservationIgnored private(set) var lastError: DeviceError?

    private func finish(_ phase: TransferJob.Phase, error: DeviceError? = nil) {
        active?.phase = phase
        active?.finishedAt = Date()
        lastError = error
    }

    private func end() async {
        guard let job = active else { return }
        await onJobEnded?(job)
        active = nil
        remember(job)
    }

    private func remember(_ job: TransferJob) {
        recent.insert(job, at: 0)
        if recent.count > 20 { recent.removeLast(recent.count - 20) }
    }
}
