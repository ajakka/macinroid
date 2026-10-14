import Foundation
@testable import Macinroid

/// The device's side of an MTP conversation, for testing the engine without a phone.
///
/// It parses the containers the host writes and answers the way a phone does:
/// as a stream of USB packets in which a transfer ends on a short packet, or
/// on an empty one when the data fills its last packet exactly. Its storages
/// are folders on disk, so tests can prepare and inspect them with ordinary files.
final class FakeMTPDevice: MTPTransport, @unchecked Sendable {
    // MARK: Behaviour that tests can change

    /// Sends the header of a data phase as a packet of its own, as some devices do.
    var sendsSeparateHeader = false
    /// Describes every file as "too large for the size field".
    var hidesSizes = false
    /// Announces data without saying how long it is.
    var hidesDataLength = false
    /// Answers the next request for the operation with this code instead of doing it.
    var failures: [UInt16: MTPResponseCode] = [:]
    /// What the phone does while its owner has not allowed access yet.
    var storagesAnswer = StoragesAnswer.normal
    /// Refuses data once this many bytes of an object have arrived.
    var storeFullAfter: Int?
    /// Does not come back in step after a cancelled transfer.
    var staysConfusedAfterCancel = false
    /// Called after every transfer on the bulk pipes, with the number of
    /// bytes of object data that have crossed since the last command. Lets a
    /// test act at an exact point of a transfer.
    var onDataTransferred: ((Int) -> Void)?

    enum StoragesAnswer {
        case normal, none, truncated
    }

    // MARK: What happened, for tests to check

    private(set) var operations: [UInt16] = []
    private(set) var cancelRequests = 0
    private(set) var isClosed = false
    private(set) var wasReset = false
    private(set) var sawSeparateHeaderFromHost = false

    // MARK: MTPTransport

    let identity = DeviceInfo.USB(vendorId: 0x18D1, productId: 0x4EE1, deviceRelease: 0x0528, manufacturer: "Google", product: "Fake Phone", serialNumber: "FAKE0001")
    let inPacketSize: Int
    let outPacketSize: Int

    private let lock = NSLock()
    private var isUnplugged = false
    private var sessionIsOpen = false
    private var isConfused = false

    // objects
    private struct Object {
        var storage: UInt32
        /// 0 for objects at the top of a storage.
        var parent: UInt32
        var name: String
        var isFolder: Bool
        var url: URL
    }

    private var storages: [(id: UInt32, name: String, root: URL)] = []
    private var objects: [UInt32: Object] = [:]
    private var nextHandle: UInt32 = 1

    // the conversation
    private enum Phase {
        case command
        case receiving(code: UInt16, transaction: UInt32, parameters: [UInt32], expected: Int?, data: Data, sawHeader: Bool)
    }

    private var phase = Phase.command
    /// What the device has queued for the host: transfers, each ending short or with an empty packet.
    private var outgoing: [Data] = []
    private var pendingEmptyPacket = false
    private var announced: (handle: UInt32, size: Int?)?
    private var dataBytes = 0

    init(root: URL, packetSize: Int = 512) {
        inPacketSize = packetSize
        outPacketSize = packetSize
        for (id, name) in [(UInt32(0x0001_0001), "Internal shared storage"), (UInt32(0x0002_0001), "SD card")] {
            let folder = root.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            storages.append((id, name, folder))
        }
        rescan()
    }

    /// The folder behind the internal storage.
    var internalRoot: URL { storages[0].root }
    let internalStorage: UInt32 = 0x0001_0001

    /// Takes stock of the files on disk again, as after a test has changed them.
    func rescan() {
        lock.lock()
        defer { lock.unlock() }

        objects = [:]
        for storage in storages {
            add(contentsOf: storage.root, parent: 0, storage: storage.id)
        }
    }

    private func add(contentsOf folder: URL, parent: UInt32, storage: UInt32) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let handle = nextHandle
            nextHandle += 1
            objects[handle] = Object(storage: storage, parent: parent, name: url.lastPathComponent, isFolder: isFolder, url: url)
            if isFolder { add(contentsOf: url, parent: handle, storage: storage) }
        }
    }

    /// Pulls the cable.
    func unplug() {
        lock.lock()
        isUnplugged = true
        lock.unlock()
    }

    func write(_ data: Data, timeout: TimeInterval) throws {
        try receive(data)
        onDataTransferred?(lock.withLock { dataBytes })
    }

    private func receive(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkPluggedIn()

        switch phase {
        case .command:
            // an empty packet after a finished data phase is of no interest
            guard !data.isEmpty else { return }
            try receiveCommand(data)

        case .receiving(let code, let transaction, let parameters, var expected, var received, var sawHeader):
            var payload = data
            if !sawHeader {
                guard data.count >= 12 else { return confuse() }
                var reader = MTPReader(data.prefix(12))
                let length = (try? reader.u32()) ?? 0
                guard (try? reader.u16()) == 2 else { return confuse() }
                expected = length == 0xFFFF_FFFF ? announced?.size : Int(length) - 12
                payload = data.dropFirst(12)
                sawHeader = true
                if data.count == 12, (expected ?? 1) > 0 { sawSeparateHeaderFromHost = true }
            }
            received.append(payload)
            dataBytes += payload.count

            let isComplete = expected.map { received.count >= $0 } ?? (data.count % outPacketSize != 0 || data.isEmpty)
            if isComplete {
                phase = .command
                finish(code: code, transaction: transaction, parameters: parameters, data: received)
            } else {
                phase = .receiving(code: code, transaction: transaction, parameters: parameters, expected: expected, data: received, sawHeader: sawHeader)
            }
        }
    }

    func read(capacity: Int, timeout: TimeInterval) throws -> Data {
        let data = try nextTransfer(capacity: capacity)
        onDataTransferred?(lock.withLock { dataBytes })
        return data
    }

    private func nextTransfer(capacity: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try checkPluggedIn()

        if pendingEmptyPacket {
            pendingEmptyPacket = false
            return Data()
        }
        guard !outgoing.isEmpty else {
            throw MTPTransportError(kind: .timeout, detail: "the fake device has nothing to say")
        }

        let transfer = outgoing[0]
        let chunk = transfer.prefix(capacity)
        let rest = transfer.dropFirst(chunk.count)

        if rest.isEmpty {
            outgoing.removeFirst()
            // A transfer that fills its last packet is followed by an empty
            // one. A read that had room to spare has taken that in already.
            if transfer.count % inPacketSize == 0, chunk.count == capacity {
                pendingEmptyPacket = true
            }
        } else {
            outgoing[0] = Data(rest)
        }
        dataBytes += chunk.count
        return Data(chunk)
    }

    func cancelRequest(transactionID: UInt32) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkPluggedIn()

        cancelRequests += 1
        if case .receiving = phase { discardAnnouncedObject() }
        phase = .command
        outgoing = []
        pendingEmptyPacket = false
        isConfused = staysConfusedAfterCancel
    }

    func deviceStatus() throws -> MTPResponseCode {
        lock.lock()
        defer { lock.unlock() }
        try checkPluggedIn()
        return .ok
    }

    func clearStalls() {}

    func resetDevice() {
        lock.lock()
        defer { lock.unlock() }
        wasReset = true
        sessionIsOpen = false
        isConfused = false
        phase = .command
        outgoing = []
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
    }

    private func checkPluggedIn() throws {
        if isUnplugged {
            throw MTPTransportError(kind: .disconnected, detail: "the fake device was unplugged")
        }
    }

    private func confuse() {
        isConfused = true
    }

    // MARK: Commands

    private func receiveCommand(_ data: Data) throws {
        var reader = MTPReader(data)
        guard let length = try? reader.u32(), let type = try? reader.u16(), let code = try? reader.u16(),
              let transaction = try? reader.u32(), type == 1, Int(length) == data.count
        else {
            return confuse()
        }
        var parameters: [UInt32] = []
        while let parameter = try? reader.u32() { parameters.append(parameter) }

        operations.append(code)
        dataBytes = 0
        if isConfused {
            // a device that has lost its place answers nothing sensible
            return
        }
        if let failure = failures.removeValue(forKey: code) {
            return respond(failure, transaction: transaction)
        }

        let needsData: Set<UInt16> = [MTPOperation.sendObjectInfo.rawValue, MTPOperation.sendObject.rawValue, MTPOperation.setObjectPropValue.rawValue]
        if needsData.contains(code) {
            phase = .receiving(code: code, transaction: transaction, parameters: parameters, expected: nil, data: Data(), sawHeader: false)
            return
        }
        finish(code: code, transaction: transaction, parameters: parameters, data: Data())
    }

    /// Carries out an operation once all of its data has arrived.
    private func finish(code: UInt16, transaction: UInt32, parameters: [UInt32], data: Data) {
        guard let operation = MTPOperation(rawValue: code) else {
            return respond(MTPResponseCode(rawValue: 0x2005), transaction: transaction)
        }
        func parameter(_ index: Int) -> UInt32 { parameters.indices.contains(index) ? parameters[index] : 0 }

        if operation != .getDeviceInfo, operation != .openSession, !sessionIsOpen {
            return respond(.sessionNotOpen, transaction: transaction)
        }

        switch operation {
        case .getDeviceInfo:
            var writer = MTPWriter()
            writer.u16(100)
            writer.u32(6)
            writer.u16(100)
            try? writer.string("microsoft.com: 1.0; android.com: 1.0;")
            writer.u16(0)
            for list: [UInt16] in [[0x1001, 0x1002, 0x9803], [], [], [], [0x3000, 0x3001]] {
                writer.u32(UInt32(list.count))
                list.forEach { writer.u16($0) }
            }
            for text in ["Google", "Fake Phone", "16", "FAKE0001"] { try? writer.string(text) }
            send(writer.data, code: code, transaction: transaction)

        case .openSession:
            if sessionIsOpen { return respond(.sessionAlreadyOpen, transaction: transaction) }
            sessionIsOpen = true
            respond(.ok, transaction: transaction)

        case .closeSession:
            sessionIsOpen = false
            respond(.ok, transaction: transaction)

        case .getStorageIDs:
            var writer = MTPWriter()
            switch storagesAnswer {
            case .normal:
                writer.u32(UInt32(storages.count))
                storages.forEach { writer.u32($0.id) }
            case .none:
                writer.u32(0)
            case .truncated:
                break
            }
            send(writer.data, code: code, transaction: transaction)

        case .getStorageInfo:
            guard let storage = storages.first(where: { $0.id == parameter(0) }) else {
                return respond(MTPResponseCode(rawValue: 0x2008), transaction: transaction)
            }
            var writer = MTPWriter()
            writer.u16(storage.id == internalStorage ? 3 : 4)
            writer.u16(2)
            writer.u16(0)
            writer.u64(256_000_000_000)
            writer.u64(114_700_000_000)
            writer.u32(0x3FFF_FFFF)
            try? writer.string(storage.name)
            try? writer.string("")
            send(writer.data, code: code, transaction: transaction)

        case .getObjectHandles:
            let parent = parameter(2) == MTPHandle.root ? 0 : parameter(2)
            let handles = objects.filter { $0.value.storage == parameter(0) && $0.value.parent == parent }.keys.sorted()
            var writer = MTPWriter()
            writer.u32(UInt32(handles.count))
            handles.forEach { writer.u32($0) }
            send(writer.data, code: code, transaction: transaction)

        case .getObjectInfo:
            guard let object = objects[parameter(0)] else { return respond(.invalidObjectHandle, transaction: transaction) }
            var info = MTPObjectInfo()
            info.storageID = object.storage
            info.objectFormat = object.isFolder ? MTPObjectFormat.association : MTPObjectFormat.undefined
            info.parentObject = object.parent
            info.filename = object.name
            let values = try? object.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            info.compressedSize = hidesSizes && !object.isFolder ? MTPObjectInfo.sizeUnknown : UInt32(clamping: values?.fileSize ?? 0)
            info.modificationDate = values?.contentModificationDate
            send((try? info.encoded()) ?? Data(), code: code, transaction: transaction)

        case .getObjectPropValue:
            guard let object = objects[parameter(0)] else { return respond(.invalidObjectHandle, transaction: transaction) }
            var writer = MTPWriter()
            switch UInt16(truncatingIfNeeded: parameter(1)) {
            case MTPObjectProperty.objectFileName:
                try? writer.string(object.name)
            case MTPObjectProperty.objectSize:
                writer.u64(UInt64((try? object.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            default:
                return respond(MTPResponseCode(rawValue: 0xA801), transaction: transaction)
            }
            send(writer.data, code: code, transaction: transaction)

        case .setObjectPropValue:
            guard var object = objects[parameter(0)] else { return respond(.invalidObjectHandle, transaction: transaction) }
            var reader = MTPReader(data)
            guard let name = try? reader.string(), !name.isEmpty else {
                return respond(MTPResponseCode(rawValue: 0xA803), transaction: transaction)
            }
            let renamed = object.url.deletingLastPathComponent().appendingPathComponent(name)
            guard (try? FileManager.default.moveItem(at: object.url, to: renamed)) != nil else {
                return respond(MTPResponseCode(rawValue: 0x2002), transaction: transaction)
            }
            let handle = parameter(0)
            let oldPrefix = object.url.path + "/"
            object.name = name
            object.url = renamed
            objects[handle] = object
            for (key, child) in objects where child.url.path.hasPrefix(oldPrefix) {
                objects[key]?.url = URL(fileURLWithPath: renamed.path + "/" + child.url.path.dropFirst(oldPrefix.count))
            }
            respond(.ok, transaction: transaction)

        case .deleteObject:
            guard let object = objects[parameter(0)] else { return respond(.invalidObjectHandle, transaction: transaction) }
            try? FileManager.default.removeItem(at: object.url)
            let prefix = object.url.path + "/"
            objects = objects.filter { $0.key != parameter(0) && !$0.value.url.path.hasPrefix(prefix) }
            respond(.ok, transaction: transaction)

        case .sendObjectInfo:
            guard let info = try? MTPObjectInfo(decoding: data), let storage = storages.first(where: { $0.id == parameter(0) }) else {
                return respond(MTPResponseCode(rawValue: 0xA806), transaction: transaction)
            }
            let parent = parameter(1) == MTPHandle.root ? 0 : parameter(1)
            let folder: URL
            if parent == 0 {
                folder = storage.root
            } else if let object = objects[parent], object.isFolder {
                folder = object.url
            } else {
                return respond(MTPResponseCode(rawValue: 0x201A), transaction: transaction)
            }
            // a phone would not take two objects of one name in a folder
            if objects.contains(where: { $0.value.storage == storage.id && $0.value.parent == parent && $0.value.name.lowercased() == info.filename.lowercased() }) {
                return respond(MTPResponseCode(rawValue: 0x2002), transaction: transaction)
            }

            let handle = nextHandle
            nextHandle += 1
            let url = folder.appendingPathComponent(info.filename)
            if info.isFolder {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                announced = nil
            } else {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                announced = (handle, info.compressedSize == MTPObjectInfo.sizeUnknown ? nil : Int(info.compressedSize))
            }
            if let date = info.modificationDate {
                try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
            objects[handle] = Object(storage: storage.id, parent: parent, name: info.filename, isFolder: info.isFolder, url: url)
            respond(.ok, transaction: transaction, parameters: [storage.id, parameter(1), handle])

        case .sendObject:
            guard let announced, let object = objects[announced.handle] else {
                return respond(MTPResponseCode(rawValue: 0x2015), transaction: transaction)
            }
            if let limit = storeFullAfter, data.count > limit {
                // a phone takes all of the data before it says that there is no room
                discardAnnouncedObject()
                return respond(.storeFull, transaction: transaction)
            }
            let modified = try? object.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try? data.write(to: object.url)
            if let modified {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: object.url.path)
            }
            self.announced = nil
            respond(.ok, transaction: transaction)

        case .getObject:
            guard let object = objects[parameter(0)], !object.isFolder, let contents = try? Data(contentsOf: object.url) else {
                return respond(.invalidObjectHandle, transaction: transaction)
            }
            send(contents, code: code, transaction: transaction)
        }
    }

    private func discardAnnouncedObject() {
        guard let announced, let object = objects[announced.handle] else { return }
        try? FileManager.default.removeItem(at: object.url)
        objects[announced.handle] = nil
        self.announced = nil
    }

    // MARK: Answers

    /// Queues a data phase and the response that follows it.
    private func send(_ payload: Data, code: UInt16, transaction: UInt32) {
        // only objects of 4 GB and more are sent without their length, so the
        // first packet of such data is always full
        let hidesLength = hidesDataLength && code == MTPOperation.getObject.rawValue && payload.count + 12 > inPacketSize

        var header = MTPWriter()
        header.u32(hidesLength ? 0xFFFF_FFFF : UInt32(payload.count + 12))
        header.u16(2)
        header.u16(code)
        header.u32(transaction)

        if sendsSeparateHeader, !payload.isEmpty {
            outgoing.append(header.data)
            outgoing.append(payload)
        } else {
            outgoing.append(header.data + payload)
        }
        respond(.ok, transaction: transaction)
    }

    private func respond(_ response: MTPResponseCode, transaction: UInt32, parameters: [UInt32] = []) {
        var writer = MTPWriter()
        writer.u32(UInt32(12 + 4 * parameters.count))
        writer.u16(3)
        writer.u16(response.rawValue)
        writer.u32(transaction)
        parameters.forEach { writer.u32($0) }
        outgoing.append(writer.data)
    }
}
