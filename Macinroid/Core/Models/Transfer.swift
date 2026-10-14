import Foundation

enum TransferDirection: String, Sendable, Codable {
    /// Mac → phone
    case upload
    /// Phone → Mac
    case download

    /// The side the files end up on.
    var destination: PaneKind { self == .upload ? .phone : .mac }
    var source: PaneKind { destination.other }
}

/// A set of files and folders to copy in one go.
struct TransferRequest: Sendable, Identifiable, Equatable {
    /// Non-zero; also what a cancellation refers to.
    let id: UInt64
    var direction: TransferDirection
    var storageID: UInt32
    /// Full paths on the source side.
    var sources: [String]
    /// The folder the sources are copied into, on the destination side.
    var destination: String
    /// Count the files first so that overall progress can be shown.
    var countFirst: Bool

    private static let nextID = Counter()

    init(direction: TransferDirection, storageID: UInt32, sources: [String], destination: String, countFirst: Bool) {
        self.id = Self.nextID.next()
        self.direction = direction
        self.storageID = storageID
        self.sources = sources
        self.destination = destination
        self.countFirst = countFirst
    }

    /// The local file a download was writing when it stopped at `devicePath`.
    func localPath(forDevicePath devicePath: String) -> String? {
        guard direction == .download else { return nil }
        for source in sources where FilePath.isSame(devicePath, orInside: source) {
            let sourceParent = FilePath.parent(of: source)
            let relative = sourceParent == FilePath.root ? devicePath : String(devicePath.dropFirst(sourceParent.count))
            return FilePath.join(destination, relative)
        }
        return nil
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}

/// A snapshot of a running transfer.
struct TransferProgress: Sendable, Equatable {
    var currentPath = ""
    var currentName = ""

    var filesDone = 0
    /// 0 when the files were not counted first.
    var filesTotal = 0

    var bytesDone: Int64 = 0
    /// 0 when the files were not counted first.
    var bytesTotal: Int64 = 0

    var fileBytesDone: Int64 = 0
    var fileBytesTotal: Int64 = 0

    var isCompleted = false

    /// Overall completion, 0…1, when the total is known.
    var fraction: Double? {
        guard bytesTotal > 0 else { return nil }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }

    var fileFraction: Double {
        guard fileBytesTotal > 0 else { return 0 }
        return min(1, Double(fileBytesDone) / Double(fileBytesTotal))
    }
}

enum TransferEvent: Sendable, Equatable {
    /// The sources are being counted.
    case counting(files: Int, bytes: Int64, currentName: String)
    case progress(TransferProgress)
}
