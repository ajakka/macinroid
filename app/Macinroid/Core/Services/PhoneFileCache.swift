import Foundation
import Observation

/// Copies of phone files on the Mac: for Quick Look, for opening them, and
/// for thumbnails that the phone cannot make itself.
///
/// Files are fetched one at a time and outside the transfer queue, so the
/// phone's files can still be browsed meanwhile. Copies that someone waits
/// for urgently, such as the file shown in Quick Look, go first.
@MainActor
@Observable
final class PhoneFileCache {
    /// The urgent fetch in progress, once it has taken long enough to be worth showing.
    struct Fetch: Equatable {
        var name: String
        var bytesDone: Int64
        var bytesTotal: Int64
    }

    private(set) var current: Fetch?

    /// Called when a fetch has ended the session, as stopping in the middle of a file can.
    @ObservationIgnored var onSessionEnded: (@MainActor (DeviceError) async -> Void)?

    @ObservationIgnored private let backend: any DeviceBackend
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var copies: [Key: Copy] = [:]
    @ObservationIgnored private var pending: [Request] = []
    @ObservationIgnored private var running: Request?
    @ObservationIgnored private var runner: Task<Void, Never>?

    /// How much the copies may take up before the oldest are thrown away.
    @ObservationIgnored var budget: Int64 = 2 << 30
    /// A fetch nobody waits for any more is still finished when no more than this is left.
    private static let worthFinishing: Int64 = 16 << 20

    private struct Key: Hashable {
        var storage: UInt32
        var path: String
        var size: Int64
        var modified: Date?

        init(_ item: FileItem, storage: UInt32) {
            self.storage = storage
            path = item.path
            size = item.size
            modified = item.modified
        }
    }

    private struct Copy {
        var url: URL
        var size: Int64
        var lastUse: Date
    }

    private final class Request {
        let key: Key
        let item: FileItem
        var isUrgent: Bool
        var waiters: [UUID: CheckedContinuation<URL, any Error>] = [:]
        var transferID: UInt64?
        var bytesDone: Int64 = 0

        init(key: Key, item: FileItem, isUrgent: Bool) {
            self.key = key
            self.item = item
            self.isUrgent = isUrgent
        }
    }

    init(backend: any DeviceBackend, folder: URL) {
        self.backend = backend
        self.folder = folder
    }

    // MARK: Copies

    /// The copy of a file fetched earlier, if it is still there.
    func localCopy(of item: FileItem, storage: UInt32) -> URL? {
        let key = Key(item, storage: storage)
        guard let copy = copies[key] else { return nil }
        guard FileManager.default.fileExists(atPath: copy.url.path) else {
            copies[key] = nil
            return nil
        }
        copies[key]?.lastUse = Date()
        return copy.url
    }

    /// Returns a copy of the file, fetching it if need be. Cancelling the
    /// calling task stops waiting; the fetch itself stops too unless it is
    /// nearly done or someone else still waits for it.
    func fetch(_ item: FileItem, storage: UInt32, urgent: Bool) async throws -> URL {
        if let url = localCopy(of: item, storage: storage) { return url }

        let key = Key(item, storage: storage)
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let request = request(for: key, item: item, urgent: urgent)
                request.waiters[id] = continuation
                startRunner()
            }
        } onCancel: {
            Task { @MainActor in self.withdraw(id, key: key) }
        }
    }

    /// Stops all fetching and returns once nothing is in flight any more.
    func stopAll() async {
        for request in pending {
            request.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        }
        pending = []
        if let running {
            running.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
            running.waiters = [:]
            if let id = running.transferID { backend.cancelTransfer(id: id) }
        }
        await runner?.value
    }

    /// Throws all copies away.
    func removeAll() {
        for copy in copies.values {
            try? FileManager.default.removeItem(at: copy.url.deletingLastPathComponent())
        }
        copies = [:]
    }

    private func request(for key: Key, item: FileItem, urgent: Bool) -> Request {
        if let running, running.key == key {
            running.isUrgent = running.isUrgent || urgent
            return running
        }
        if let index = pending.firstIndex(where: { $0.key == key }) {
            let request = pending[index]
            if urgent, !request.isUrgent {
                request.isUrgent = true
                // to the back, where the newest urgent request is taken from
                pending.remove(at: index)
                pending.append(request)
            }
            return request
        }
        let request = Request(key: key, item: item, isUrgent: urgent)
        pending.append(request)
        return request
    }

    private func withdraw(_ id: UUID, key: Key) {
        if let index = pending.firstIndex(where: { $0.key == key }) {
            let request = pending[index]
            request.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            if request.waiters.isEmpty { pending.remove(at: index) }
        } else if let running, running.key == key {
            running.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            if running.waiters.isEmpty, running.item.size - running.bytesDone > Self.worthFinishing, let transfer = running.transferID {
                backend.cancelTransfer(id: transfer)
            }
        }
    }

    // MARK: Fetching

    private func startRunner() {
        guard runner == nil else { return }
        runner = Task {
            while let next = takeNext() {
                await perform(next)
            }
            runner = nil
        }
    }

    /// The newest urgent request, or else the oldest of the others.
    private func takeNext() -> Request? {
        if let index = pending.lastIndex(where: \.isUrgent) {
            return pending.remove(at: index)
        }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    private func perform(_ request: Request) async {
        running = request
        defer {
            running = nil
            current = nil
        }

        let destination = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let transfer = TransferRequest(
            direction: .download, storageID: request.key.storage, sources: [request.item.path],
            destination: destination.path, countFirst: false
        )
        request.transferID = transfer.id

        // a quick fetch is over before anyone could read about it
        let announcement = Task {
            try await Task.sleep(for: .milliseconds(400))
            if request.isUrgent {
                current = Fetch(name: request.item.name, bytesDone: request.bytesDone, bytesTotal: request.item.size)
            }
        }
        defer { announcement.cancel() }

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for try await event in backend.transfer(transfer) {
                guard case .progress(let progress) = event else { continue }
                request.bytesDone = progress.bytesDone
                if current != nil {
                    current?.bytesDone = progress.bytesDone
                }
            }

            let url = destination.appendingPathComponent(request.item.name)
            copies[request.key] = Copy(url: url, size: request.item.size, lastUse: Date())
            evict(keeping: request.key)
            request.waiters.values.forEach { $0.resume(returning: url) }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            let error = DeviceError(error)
            request.waiters.values.forEach { $0.resume(throwing: error) }
            request.waiters = [:]
            if error.endsSession {
                await onSessionEnded?(error)
            }
        }
        request.waiters = [:]
    }

    /// Throws away the copies used longest ago until they fit the budget.
    private func evict(keeping kept: Key) {
        var total = copies.values.reduce(0) { $0 + $1.size }
        for (key, copy) in copies.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
            guard total > budget else { break }
            guard key != kept else { continue }
            try? FileManager.default.removeItem(at: copy.url.deletingLastPathComponent())
            copies[key] = nil
            total -= copy.size
        }
    }
}
