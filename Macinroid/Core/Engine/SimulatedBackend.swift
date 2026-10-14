import CoreGraphics
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// A stand-in for a phone, backed by a folder on the Mac.
///
/// It lets the whole app — browsing, transfers, cancellation, conflicts,
/// unplugging — be exercised without hardware, by the unit tests and by
/// launching the app with `-SimulatedDevice YES`.
actor SimulatedBackend: DeviceBackend {
    struct Configuration: Sendable {
        /// The folder that holds the pretend storages.
        var root: URL
        var deviceName = "Pixel 9 Pro"
        /// Throttles transfers so that progress is visible; nil copies at full speed.
        var bytesPerSecond: Int64? = 24 << 20
        /// Fill an empty device with folders and files that look like a phone's.
        var seedSampleContent = true
    }

    private struct Storage {
        var info: StorageInfo
        var root: URL
    }

    nonisolated let configuration: Configuration

    private var isConnected = false
    private let attached = OSAllocatedUnfairLock(initialState: true)
    private let cancelledTransfers = OSAllocatedUnfairLock(initialState: Set<UInt64>())

    private static let disallowedNames: Set<String> = [".DS_Store"]

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Pretends that the cable was unplugged or plugged back in.
    nonisolated func setAttached(_ isAttached: Bool) {
        attached.withLock { $0 = isAttached }
    }

    nonisolated var isAttached: Bool {
        attached.withLock { $0 }
    }

    // MARK: DeviceBackend

    func connect() async throws -> DeviceInfo {
        guard isAttached else {
            isConnected = false
            throw DeviceError(code: .mtpDetectFailed, detail: "no MTP devices found")
        }

        let internalRoot = try storageList()[0].root
        if configuration.seedSampleContent,
           (try? FileManager.default.contentsOfDirectory(atPath: internalRoot.path))?.isEmpty ?? true {
            try SampleContent.create(in: internalRoot)
        }

        isConnected = true

        return DeviceInfo(
            mtp: .init(
                manufacturer: "Google",
                model: configuration.deviceName,
                deviceVersion: "16",
                serialNumber: "SIMULATED0001",
                standardVersion: 100,
                mtpVersion: 100,
                mtpExtension: "microsoft.com: 1.0; android.com: 1.0;"
            ),
            usb: .init(
                vendorId: 0x18D1,
                productId: 0x4EE1,
                deviceRelease: 0x0528,
                manufacturer: "Google",
                product: configuration.deviceName,
                serialNumber: "SIMULATED0001"
            )
        )
    }

    func disconnect() async {
        isConnected = false
    }

    func storages() async throws -> [StorageInfo] {
        try requireSession()
        return try storageList().map(\.info)
    }

    func list(storage: UInt32, path: String, includeHidden: Bool) async throws -> [FileItem] {
        let directory = try url(storage: storage, path: path)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DeviceError(code: .invalidPath, detail: "path not found: \(path)")
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)

        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard !Self.disallowedNames.contains(name), includeHidden || !name.hasPrefix(".") else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory ?? false
            return FileItem(
                path: FilePath.join(path, name),
                name: name,
                isFolder: isFolder,
                size: isFolder ? 0 : Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate
            )
        }
    }

    func makeDirectory(storage: UInt32, path: String) async throws {
        let directory = try url(storage: storage, path: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func exists(storage: UInt32, paths: [String]) async throws -> [Bool] {
        try paths.map { FileManager.default.fileExists(atPath: try url(storage: storage, path: $0).path) }
    }

    func delete(storage: UInt32, paths: [String]) async throws {
        for path in paths {
            let item = try url(storage: storage, path: path)
            if FileManager.default.fileExists(atPath: item.path) {
                try FileManager.default.removeItem(at: item)
            }
        }
    }

    func rename(storage: UInt32, path: String, newName: String) async throws {
        let item = try url(storage: storage, path: path)
        guard FileManager.default.fileExists(atPath: item.path) else {
            throw DeviceError(code: .invalidPath, detail: "file not found: \(path)")
        }
        try FileManager.default.moveItem(at: item, to: item.deletingLastPathComponent().appendingPathComponent(newName))
    }

    nonisolated func transfer(_ request: TransferRequest) -> AsyncThrowingStream<TransferEvent, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await self.perform(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: DeviceError(error))
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    nonisolated func cancelTransfer(id: UInt64) {
        cancelledTransfers.withLock { _ = $0.insert(id) }
    }

    func debugReport() async -> String {
        "Simulated device “\(configuration.deviceName)” at \(configuration.root.path)\n"
    }

    // MARK: Storage layout

    private func requireSession() throws {
        guard isAttached else {
            isConnected = false
            throw DeviceError(code: .deviceChanged, detail: "the device is gone")
        }
        guard isConnected else { throw DeviceError.notConnected }
    }

    private func storageList() throws -> [Storage] {
        let definitions: [(id: UInt32, folder: String, name: String, capacity: UInt64, used: UInt64, removable: Bool)] = [
            (0x0001_0001, "Internal", "Internal shared storage", 256_000_000_000, 141_300_000_000, false),
            (0x0002_0001, "SD Card", "SD card", 64_000_000_000, 12_800_000_000, true),
        ]

        return try definitions.map { definition in
            let root = configuration.root.appendingPathComponent(definition.folder, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return Storage(
                info: StorageInfo(
                    id: definition.id,
                    description: definition.name,
                    capacity: definition.capacity,
                    freeSpace: definition.capacity - definition.used,
                    storageType: definition.removable ? 4 : 3,
                    filesystemType: 2,
                    isRemovable: definition.removable
                ),
                root: root
            )
        }
    }

    private func url(storage: UInt32, path: String) throws -> URL {
        try requireSession()
        guard let root = try storageList().first(where: { $0.info.id == storage })?.root else {
            throw DeviceError(code: .noStorage, detail: "StoreNotAvailable")
        }
        let relative = FilePath.normalize(path).dropFirst()
        return relative.isEmpty ? root : root.appendingPathComponent(String(relative))
    }

    // MARK: Transfers

    private struct PlannedFile {
        var source: URL
        var destination: URL
        /// The path reported as "current": on the device, as the real engine does.
        var devicePath: String
        var size: Int64
    }

    private nonisolated func perform(_ request: TransferRequest, emit: (TransferEvent) -> Void) async throws {
        defer { cancelledTransfers.withLock { _ = $0.remove(request.id) } }

        let isUpload = request.direction == .upload
        let deviceDestination = isUpload ? try await url(storage: request.storageID, path: request.destination) : nil

        // work out what goes where
        var files: [PlannedFile] = []
        var directories: [URL] = []
        var totalBytes: Int64 = 0

        for source in request.sources {
            let sourceURL = isUpload
                ? URL(fileURLWithPath: source)
                : try await url(storage: request.storageID, path: source)
            let sourceParentPath = FilePath.parent(of: source)
            let destinationRoot = deviceDestination ?? URL(fileURLWithPath: request.destination)

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
                throw DeviceError(code: .invalidPath, detail: "file not found: \(source)")
            }

            // `relative` is the item's path below the folder that holds the source
            func plan(_ url: URL, relative: String, isDirectory: Bool) {
                guard !Self.disallowedNames.contains(url.lastPathComponent) else { return }
                let destination = destinationRoot.appendingPathComponent(relative)
                if isDirectory {
                    directories.append(destination)
                    return
                }
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let devicePath = isUpload
                    ? FilePath.join(request.destination, relative)
                    : FilePath.join(sourceParentPath, relative)
                files.append(PlannedFile(source: url, destination: destination, devicePath: devicePath, size: size))
                totalBytes += size
                if request.countFirst, files.count % 25 == 1 {
                    emit(.counting(files: files.count, bytes: totalBytes, currentName: url.lastPathComponent))
                }
            }

            let name = sourceURL.lastPathComponent
            plan(sourceURL, relative: name, isDirectory: isDirectory.boolValue)
            if isDirectory.boolValue, let enumerator = FileManager.default.enumerator(atPath: sourceURL.path) {
                while let subpath = enumerator.nextObject() as? String {
                    try checkCancellation(request)
                    let url = sourceURL.appendingPathComponent(subpath)
                    let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    plan(url, relative: name + "/" + subpath, isDirectory: isFolder)
                }
            }
        }

        if request.countFirst {
            emit(.counting(files: files.count, bytes: totalBytes, currentName: files.last?.source.lastPathComponent ?? ""))
        }

        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // copy
        var progress = TransferProgress(
            filesTotal: request.countFirst ? files.count : 0,
            bytesTotal: request.countFirst ? totalBytes : 0
        )
        let chunkSize = 256 << 10

        for file in files {
            progress.currentPath = file.devicePath
            progress.currentName = file.source.lastPathComponent
            progress.fileBytesDone = 0
            progress.fileBytesTotal = file.size
            emit(.progress(progress))

            try FileManager.default.createDirectory(at: file.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: file.destination.path, contents: nil) else {
                throw DeviceError(code: isUpload ? .sendObject : .filePermission, detail: "cannot create \(file.destination.path)")
            }

            let reader = try FileHandle(forReadingFrom: file.source)
            let writer = try FileHandle(forWritingTo: file.destination)
            defer {
                try? reader.close()
                try? writer.close()
            }

            do {
                while let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty {
                    try checkCancellation(request)
                    try checkAttached()
                    try writer.write(contentsOf: chunk)

                    progress.fileBytesDone += Int64(chunk.count)
                    progress.bytesDone += Int64(chunk.count)
                    emit(.progress(progress))

                    if let rate = configuration.bytesPerSecond, rate > 0 {
                        try await Task.sleep(for: .nanoseconds(Int64(chunk.count) * 1_000_000_000 / rate))
                    }
                }
            } catch {
                try? writer.close()
                try? FileManager.default.removeItem(at: file.destination)
                throw error
            }

            if let modified = try? file.source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.destination.path)
            }

            progress.filesDone += 1
        }

        progress.isCompleted = true
        emit(.progress(progress))
    }

    private nonisolated func checkCancellation(_ request: TransferRequest) throws {
        if Task.isCancelled || cancelledTransfers.withLock({ $0.contains(request.id) }) {
            throw DeviceError(code: .transferCancelled, detail: "the transfer was cancelled")
        }
    }

    private nonisolated func checkAttached() throws {
        if !isAttached {
            throw DeviceError(code: .fileTransfer, detail: "the device is gone", sessionReset: true)
        }
    }
}

/// Folders and files that make an empty simulated device look lived-in.
private enum SampleContent {
    static func create(in root: URL) throws {
        let fileManager = FileManager.default
        let folders = [
            "Alarms", "Android/data", "Android/media", "Audiobooks", "DCIM/Camera", "Documents", "Download",
            "Movies", "Music/Podcasts", "Notifications", "Pictures/Screenshots", "Pictures/WhatsApp", "Recordings", "Ringtones",
        ]
        for folder in folders {
            try fileManager.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }

        let calendar = Calendar.current
        let now = Date()

        // photos
        for index in 0..<18 {
            let date = calendar.date(byAdding: .hour, value: -index * 31, to: now) ?? now
            let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.omitted))
            let time = date.formatted(.iso8601.time(includingFractionalSeconds: false).timeSeparator(.omitted)).prefix(6)
            let url = root.appendingPathComponent("DCIM/Camera/IMG_\(stamp)_\(time).jpg")
            try writeImage(to: url, hue: Double(index) / 18, type: .jpeg, size: CGSize(width: 1600, height: 1200))
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        for index in 0..<5 {
            let date = calendar.date(byAdding: .day, value: -index * 3 - 1, to: now) ?? now
            let url = root.appendingPathComponent("Pictures/Screenshots/Screenshot_\(index + 1).png")
            try writeImage(to: url, hue: 0.55 + Double(index) / 25, type: .png, size: CGSize(width: 540, height: 1200))
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        // documents and downloads
        let texts: [(String, String)] = [
            ("Documents/Packing list.txt", "Passport\nCharger\nUSB-C cable\nHeadphones\n"),
            ("Documents/Notes.md", "# Notes\n\n- Back up the phone\n- Free up storage\n"),
            ("Documents/Budget.csv", "month,rent,food\nJanuary,900,310\nFebruary,900,295\n"),
            ("Download/readme.html", "<!doctype html><title>Read me</title><p>Hello from the phone.</p>\n"),
            ("Download/contacts.vcf", "BEGIN:VCARD\nVERSION:3.0\nFN:Ada Lovelace\nEND:VCARD\n"),
        ]
        for (path, text) in texts {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }

        // larger files, so that a transfer takes long enough to watch
        let blobs: [(String, Int)] = [
            ("Movies/VID_20260912_184502.mp4", 48 << 20),
            ("Movies/VID_20260930_101733.mp4", 21 << 20),
            ("Download/ubuntu-notes.pdf", 3 << 20),
            ("Download/app-release.apk", 12 << 20),
            ("Music/Podcasts/episode-142.mp3", 24 << 20),
            ("Music/Morning Mix.flac", 16 << 20),
            ("Recordings/Voice 001.m4a", 2 << 20),
            ("Ringtones/Marimba.ogg", 300 << 10),
        ]
        for (path, size) in blobs {
            try writeBlob(to: root.appendingPathComponent(path), size: size)
        }
    }

    private static func writeBlob(to url: URL, size: Int) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var chunk = Data(count: 1 << 20)
        chunk.withUnsafeMutableBytes { buffer in
            for index in buffer.indices { buffer[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7) }
        }
        var remaining = size
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            try handle.write(contentsOf: chunk.prefix(count))
            remaining -= count
        }
    }

    private static func writeImage(to url: URL, hue: Double, type: UTType, size: CGSize) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        func color(_ hue: Double, _ brightness: Double) -> CGColor {
            // a compact HSB → RGB conversion, enough for a pleasant gradient
            let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
            let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
            let (r, g, b): (Double, Double, Double) = switch Int(h) {
            case 0: (1, x, 0)
            case 1: (x, 1, 0)
            case 2: (0, 1, x)
            case 3: (0, x, 1)
            case 4: (x, 0, 1)
            default: (1, 0, x)
            }
            let mix = 0.45
            return CGColor(
                red: (r * (1 - mix) + mix) * brightness,
                green: (g * (1 - mix) + mix) * brightness,
                blue: (b * (1 - mix) + mix) * brightness,
                alpha: 1
            )
        }

        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [color(hue, 0.95), color(hue + 0.12, 0.6)] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
        context.fillEllipse(in: CGRect(x: size.width * 0.55, y: size.height * 0.5, width: size.width * 0.3, height: size.width * 0.3))

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
