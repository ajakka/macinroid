import Foundation

/// A file or folder on the device.
struct MTPFile: Equatable {
    var handle: UInt32
    var parent: UInt32
    var name: String
    var path: String
    var isFolder: Bool
    var size: Int64
    var modified: Date?
    var hasThumbnail = false

    static func root() -> MTPFile {
        MTPFile(handle: MTPHandle.root, parent: MTPHandle.root, name: "", path: FilePath.root, isFolder: true, size: 0)
    }

    var fileItem: FileItem {
        FileItem(path: path, name: name, isFolder: isFolder, size: size, modified: modified, hasThumbnail: hasThumbnail)
    }
}

/// What a transfer needs from its surroundings.
struct MTPTransferHooks {
    /// Asked between pieces of work; a transfer stops soon after this turns true.
    var isCancelled: () -> Bool
    var emit: (TransferEvent) -> Void
}

/// Files and folders on top of MTP's objects and handles: paths, listings,
/// and copying whole trees in either direction.
///
/// MTP knows nothing of paths. An object is found by walking down from the
/// top of its storage, comparing names, so what has been learned about a
/// folder is remembered for the length of the connection and checked again
/// before it is relied on.
final class MTPFileSystem {
    let session: MTPSession

    /// Files that are never copied in either direction.
    private static let disallowedNames: Set<String> = [".DS_Store"]

    /// The names inside folders that have been looked at, lowercased.
    private var childrenByFolder: [FolderKey: [String: UInt32]] = [:]
    /// The folders whose names were read during the operation in progress.
    /// Only those are trusted to say that a name is *not* there.
    private var foldersReadThisOperation: Set<FolderKey> = []

    private struct FolderKey: Hashable {
        var storage: UInt32
        var handle: UInt32
    }

    init(session: MTPSession) {
        self.session = session
    }

    /// Marks the start of a request from the app. What is remembered from
    /// earlier requests may have changed on the phone in the meantime.
    func beginOperation() {
        foldersReadThisOperation.removeAll()
    }

    // MARK: Storages

    func storages() throws -> [StorageInfo] {
        let ids: [UInt32]
        do {
            ids = try session.getStorageIDs()
        } catch MTPCodingError.truncated {
            // what a phone answers while it is still asking its owner for permission
            throw DeviceError(code: .allowStorageAccess, detail: "the list of storages is empty", sessionReset: true)
        } catch {
            throw deviceError(error, or: .storageInfo)
        }
        guard !ids.isEmpty else {
            throw DeviceError(code: .noStorage, detail: "no storage found")
        }

        return try ids.map { id in
            let info: MTPStorageInfo
            do {
                info = try session.getStorageInfo(id)
            } catch MTPCodingError.truncated {
                throw DeviceError(code: .allowStorageAccess, detail: "the storage information is empty", sessionReset: true)
            } catch {
                throw deviceError(error, or: .storageInfo)
            }
            return StorageInfo(
                id: id,
                description: info.storageDescription,
                volumeLabel: info.volumeLabel,
                capacity: info.maxCapacity,
                freeSpace: info.freeSpaceInBytes,
                storageType: Int(info.storageType),
                filesystemType: Int(info.filesystemType),
                accessCapability: Int(info.accessCapability),
                isRemovable: info.isRemovable
            )
        }
    }

    // MARK: Finding objects

    /// Describes the object with the given handle, which lies in `parentPath`.
    private func file(_ handle: UInt32, in parentPath: String) throws -> MTPFile {
        let info = try session.getObjectInfo(handle)

        var size = Int64(info.compressedSize)
        if info.isFolder {
            size = 0
        } else if info.compressedSize == MTPObjectInfo.sizeUnknown {
            // 4 GB and more do not fit the field; the real size is a property
            size = Int64(clamping: try session.getObjectSize(handle))
        }

        return MTPFile(
            handle: handle,
            parent: info.parentObject,
            name: info.filename,
            path: FilePath.join(parentPath, info.filename),
            isFolder: info.isFolder,
            size: size,
            modified: info.modificationDate,
            hasThumbnail: !info.isFolder && info.hasThumbnail
        )
    }

    /// The handles of what is inside a folder, by lowercased name. With
    /// `fresh`, names remembered from an earlier operation are read again.
    private func children(of folder: UInt32, storage: UInt32, fresh: Bool = false) throws -> [String: UInt32] {
        let key = FolderKey(storage: storage, handle: folder)
        if let known = childrenByFolder[key], !fresh || foldersReadThisOperation.contains(key) {
            return known
        }

        var names: [String: UInt32] = [:]
        for handle in try session.getObjectHandles(storage: storage, parent: folder) {
            names[try name(of: handle).lowercased()] = handle
        }
        childrenByFolder[key] = names
        foldersReadThisOperation.insert(key)
        return names
    }

    private func name(of handle: UInt32) throws -> String {
        do {
            return try session.getObjectFileName(handle)
        } catch let error as MTPError where error.responseCode != nil {
            // devices without object properties still describe their objects
            return try session.getObjectInfo(handle).filename
        }
    }

    /// Finds `name` in a folder. Names are compared without regard to case, as Android does.
    private func child(named name: String, of folder: MTPFile, storage: UInt32) throws -> MTPFile? {
        let key = FolderKey(storage: storage, handle: folder.handle)
        let wanted = name.lowercased()

        if let handle = try children(of: folder.handle, storage: storage)[wanted] {
            // what is remembered may be out of date; the object itself has the last word
            if let found = try? file(handle, in: folder.path), found.name.lowercased() == wanted {
                return found
            }
            childrenByFolder[key] = nil
        }

        // a name missing from what was remembered may have appeared since
        guard let handle = try children(of: folder.handle, storage: storage, fresh: true)[wanted] else { return nil }
        return try file(handle, in: folder.path)
    }

    private func remember(_ handle: UInt32?, named name: String, in folder: UInt32, storage: UInt32) {
        let key = FolderKey(storage: storage, handle: folder)
        guard childrenByFolder[key] != nil else { return }
        childrenByFolder[key]?[name.lowercased()] = handle
    }

    /// Finds the object at `path`, or returns nil when there is none.
    private func find(_ path: String, storage: UInt32) throws -> MTPFile? {
        var current = MTPFile.root()
        let components = FilePath.normalize(path).split(separator: "/").map(String.init)

        for (index, component) in components.enumerated() {
            guard let next = try child(named: component, of: current, storage: storage) else { return nil }
            // only folders have something below them
            if !next.isFolder, index < components.count - 1 { return nil }
            current = next
        }
        return current
    }

    private func resolve(_ path: String, storage: UInt32) throws -> MTPFile {
        let found: MTPFile?
        do {
            found = try find(path, storage: storage)
        } catch {
            throw deviceError(error, or: .fileObjectRead)
        }
        guard let found else {
            throw DeviceError(code: .invalidPath, detail: "path not found: \(path)")
        }
        return found
    }

    // MARK: Listing and changing

    func list(storage: UInt32, path: String, includeHidden: Bool) throws -> [MTPFile] {
        let folder = try resolve(path, storage: storage)
        guard folder.isFolder else { return [folder] }
        return try contents(of: folder, storage: storage).filter { includeHidden || !$0.name.hasPrefix(".") }
    }

    /// Everything directly inside a folder. Objects that cannot be described are left out.
    private func contents(of folder: MTPFile, storage: UInt32) throws -> [MTPFile] {
        let handles: [UInt32]
        do {
            handles = try session.getObjectHandles(storage: storage, parent: folder.handle)
        } catch {
            throw deviceError(error, or: .listDirectory)
        }

        var files: [MTPFile] = []
        var names: [String: UInt32] = [:]
        for handle in handles {
            do {
                let file = try file(handle, in: folder.path)
                files.append(file)
                names[file.name.lowercased()] = handle
            } catch let error as MTPError where error.responseCode != nil {
                continue
            } catch {
                throw deviceError(error, or: .listDirectory)
            }
        }
        // the listing doubles as the folder's table of names
        let key = FolderKey(storage: storage, handle: folder.handle)
        childrenByFolder[key] = names
        foldersReadThisOperation.insert(key)
        return files
    }

    /// Creates the folder at `path` and any that are missing above it. Returns its handle.
    @discardableResult
    func makeDirectory(storage: UInt32, path: String) throws -> UInt32 {
        var current = MTPFile.root()
        for component in FilePath.normalize(path).split(separator: "/").map(String.init) {
            current = try folder(named: component, in: current, storage: storage)
        }
        return current.handle
    }

    /// The folder `name` inside `parent`, created if it is not there yet.
    private func folder(named name: String, in parent: MTPFile, storage: UInt32) throws -> MTPFile {
        let existing: MTPFile?
        do {
            existing = try child(named: name, of: parent, storage: storage)
        } catch {
            throw deviceError(error, or: .fileObjectRead)
        }

        if let existing {
            guard existing.isFolder else {
                throw DeviceError(code: .invalidPath, detail: "invalid path: \(name). The object is not a directory")
            }
            return existing
        }

        var info = MTPObjectInfo()
        info.storageID = storage
        info.objectFormat = MTPObjectFormat.association
        info.parentObject = parent.handle
        info.filename = name
        info.modificationDate = Date()

        do {
            let handle = try session.sendObjectInfo(storage: storage, parent: parent.handle, info: info)
            remember(handle, named: name, in: parent.handle, storage: storage)
            return MTPFile(
                handle: handle, parent: parent.handle, name: name, path: FilePath.join(parent.path, name),
                isFolder: true, size: 0, modified: info.modificationDate
            )
        } catch {
            throw deviceError(error, or: .sendObject)
        }
    }

    func exists(storage: UInt32, paths: [String]) throws -> [Bool] {
        try paths.map { path in
            do {
                return try find(path, storage: storage) != nil
            } catch let error as MTPError where error.responseCode != nil {
                return false
            } catch {
                throw deviceError(error, or: .fileObjectRead)
            }
        }
    }

    /// Deletes files and folders; the device deletes a folder with everything in it.
    func delete(storage: UInt32, paths: [String]) throws {
        for path in paths {
            guard let file = try? find(path, storage: storage), file.handle != MTPHandle.root else { continue }
            do {
                try session.deleteObject(file.handle)
            } catch {
                throw deviceError(error, or: .fileObjectRead)
            }
            forget(file, storage: storage)
        }
    }

    private func forget(_ file: MTPFile, storage: UInt32) {
        // the parent's handle in the description is 0 for objects at the top
        for parent in Set([file.parent, file.parent == 0 ? MTPHandle.root : file.parent]) {
            remember(nil, named: file.name, in: parent, storage: storage)
        }
        childrenByFolder[FolderKey(storage: storage, handle: file.handle)] = nil
    }

    func rename(storage: UInt32, path: String, newName: String) throws {
        let file = try resolve(path, storage: storage)
        do {
            try session.setObjectFileName(file.handle, to: newName)
        } catch let error as MTPError where error.responseCode?.rawValue == 0x2002 {
            // some phones answer "general error" to a rename that worked
        } catch {
            throw deviceError(error, or: .fileObjectRead)
        }
        // the folder's table of names is rebuilt the next time it is needed
        childrenByFolder = childrenByFolder.filter { $0.key.storage != storage }
    }

    // MARK: Looking inside files

    /// The small picture the device keeps of a file, usually a JPEG, or nil when it has none.
    func thumbnail(storage: UInt32, path: String) throws -> Data? {
        let handle = try knownHandle(of: path, storage: storage)
        do {
            let data = try session.getThumb(handle)
            return data.isEmpty ? nil : data
        } catch let error as MTPError where error.responseCode != nil {
            // NoThumbnailPresent, or whatever else a device answers when it has none
            return nil
        } catch {
            throw deviceError(error, or: .fileObjectRead)
        }
    }

    /// Up to `length` bytes of a file from `offset`; fewer at its end.
    func read(storage: UInt32, path: String, offset: Int64, length: Int) throws -> Data {
        let handle = try knownHandle(of: path, storage: storage)
        do {
            return try session.getPartialObject(handle, offset: UInt64(max(0, offset)), length: UInt32(clamping: length))
        } catch {
            throw deviceError(error, or: .fileObjectRead)
        }
    }

    /// The handle of the object at `path`. A folder that was just listed
    /// already says which handle each of its names has, so asking about the
    /// files shown in it costs no requests beyond the one that matters.
    private func knownHandle(of path: String, storage: UInt32) throws -> UInt32 {
        var handle = MTPHandle.root
        for component in FilePath.normalize(path).split(separator: "/") {
            guard let next = childrenByFolder[FolderKey(storage: storage, handle: handle)]?[component.lowercased()] else {
                return try resolve(path, storage: storage).handle
            }
            handle = next
        }
        return handle
    }

    // MARK: Copying to the device

    private struct LocalEntry {
        var url: URL
        var isFolder: Bool
        var size: Int64
        var modified: Date?
        /// Path below the folder that holds the source, starting with the source's own name.
        var relativePath: String
    }

    /// Copies files and folders from the Mac into `request.destination`.
    func upload(_ request: TransferRequest, hooks: MTPTransferHooks) throws {
        let storage = request.storageID
        var reporter = ProgressReporter(emit: hooks.emit)

        // what there is to copy
        var entries: [LocalEntry] = []
        for source in request.sources {
            try collect(URL(fileURLWithPath: source).resolvingSymlinksInPath(), into: &entries, hooks: hooks, announce: request.countFirst)
        }
        if request.countFirst {
            let files = entries.filter { !$0.isFolder }
            reporter.progress.filesTotal = files.count
            reporter.progress.bytesTotal = files.reduce(0) { $0 + $1.size }
            hooks.emit(.counting(files: files.count, bytes: reporter.progress.bytesTotal, currentName: files.last?.url.lastPathComponent ?? ""))
        }

        // where it goes
        let destination = FilePath.normalize(request.destination)
        var folders: [String: MTPFile] = [:]
        if destination == FilePath.root {
            folders[""] = MTPFile.root()
        } else {
            try makeDirectory(storage: storage, path: destination)
            folders[""] = try resolve(destination, storage: storage)
        }

        for entry in entries {
            if hooks.isCancelled() { throw DeviceError.cancelled }

            let parentPath = (entry.relativePath as NSString).deletingLastPathComponent
            guard let parent = folders[parentPath] else {
                throw DeviceError(code: .fileTransfer, detail: "no folder for \(entry.relativePath)")
            }
            let name = entry.url.lastPathComponent

            if entry.isFolder {
                folders[entry.relativePath] = try folder(named: name, in: parent, storage: storage)
            } else {
                try send(entry, named: name, to: parent, storage: storage, reporter: &reporter, hooks: hooks)
            }
        }

        reporter.finish()
    }

    /// Lists a source and everything below it, folders before their contents.
    private func collect(_ url: URL, into entries: inout [LocalEntry], hooks: MTPTransferHooks, announce: Bool) throws {
        func add(_ url: URL, relativePath: String) throws {
            if hooks.isCancelled() { throw DeviceError.cancelled }
            guard !Self.disallowedNames.contains(url.lastPathComponent) else { return }

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            } catch {
                throw localError(error, path: url.path)
            }
            // links inside a folder are left alone: they may lead in circles
            guard values.isSymbolicLink != true else { return }

            let isFolder = values.isDirectory ?? false
            entries.append(LocalEntry(
                url: url, isFolder: isFolder, size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate, relativePath: relativePath
            ))
            if announce, !isFolder, entries.count % 50 == 0 {
                let files = entries.filter { !$0.isFolder }
                hooks.emit(.counting(files: files.count, bytes: files.reduce(0) { $0 + $1.size }, currentName: url.lastPathComponent))
            }
            guard isFolder else { return }

            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            } catch {
                throw localError(error, path: url.path)
            }
            for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                try add(child, relativePath: relativePath + "/" + child.lastPathComponent)
            }
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DeviceError(code: .invalidPath, detail: "file not found: \(url.path)")
        }
        try add(url, relativePath: url.lastPathComponent)
    }

    /// Sends one file, replacing an object of the same name.
    private func send(
        _ entry: LocalEntry, named name: String, to parent: MTPFile, storage: UInt32,
        reporter: inout ProgressReporter, hooks: MTPTransferHooks
    ) throws {
        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: entry.url)
        } catch {
            throw localError(error, path: entry.url.path)
        }
        defer { try? reader.close() }

        do {
            if let existing = try child(named: name, of: parent, storage: storage) {
                try session.deleteObject(existing.handle)
                forget(existing, storage: storage)
            }
        } catch {
            throw deviceError(error, or: .fileObjectRead)
        }

        var info = MTPObjectInfo()
        info.storageID = storage
        info.objectFormat = MTPObjectFormat.undefined
        info.compressedSize = UInt32(clamping: entry.size)
        info.parentObject = parent.handle
        info.filename = name
        info.modificationDate = entry.modified

        let handle: UInt32
        do {
            handle = try session.sendObjectInfo(storage: storage, parent: parent.handle, info: info)
        } catch {
            throw deviceError(error, or: .sendObject)
        }

        reporter.begin(name: name, path: FilePath.join(parent.path, name), size: entry.size)
        do {
            var reporterCopy = reporter
            defer { reporter = reporterCopy }
            try session.sendObject(
                MTPSession.Outgoing(size: entry.size) { count in try reader.read(upToCount: count) ?? Data() },
                progress: { sent in
                    reporterCopy.update(fileBytes: sent)
                    if hooks.isCancelled(), sent < entry.size { throw MTPError.cancelled }
                }
            )
        } catch {
            try abandon(error, or: .sendObject) {
                // the device may have kept the part that arrived
                try? session.deleteObject(handle)
            }
        }

        remember(handle, named: name, in: parent.handle, storage: storage)
        reporter.completeFile()
    }

    // MARK: Copying from the device

    private struct RemoteEntry {
        var file: MTPFile
        var localURL: URL
    }

    /// Copies files and folders from the device into `request.destination` on the Mac.
    func download(_ request: TransferRequest, hooks: MTPTransferHooks) throws {
        let storage = request.storageID
        let destination = URL(fileURLWithPath: request.destination, isDirectory: true)
        var reporter = ProgressReporter(emit: hooks.emit)

        var roots: [RemoteEntry] = []
        for source in request.sources {
            let file = try resolve(source, storage: storage)
            guard file.handle != MTPHandle.root else {
                throw DeviceError(code: .invalidPath, detail: "the whole storage cannot be copied as one item")
            }
            roots.append(RemoteEntry(file: file, localURL: destination.appendingPathComponent(file.name)))
        }

        if request.countFirst {
            // look at everything first, then copy with the total in view
            var entries: [RemoteEntry] = []
            for root in roots {
                try walk(root, storage: storage, hooks: hooks) { entry in
                    entries.append(entry)
                    if !entry.file.isFolder, entries.count % 50 == 0 {
                        let files = entries.filter { !$0.file.isFolder }
                        hooks.emit(.counting(files: files.count, bytes: files.reduce(0) { $0 + $1.file.size }, currentName: entry.file.name))
                    }
                }
            }
            let files = entries.filter { !$0.file.isFolder }
            reporter.progress.filesTotal = files.count
            reporter.progress.bytesTotal = files.reduce(0) { $0 + $1.file.size }
            hooks.emit(.counting(files: files.count, bytes: reporter.progress.bytesTotal, currentName: files.last?.file.name ?? ""))

            for entry in entries {
                try fetch(entry, reporter: &reporter, hooks: hooks)
            }
        } else {
            for root in roots {
                try walk(root, storage: storage, hooks: hooks) { entry in
                    try fetch(entry, reporter: &reporter, hooks: hooks)
                }
            }
        }

        reporter.finish()
    }

    /// Visits an object and, for a folder, everything below it, folders before their contents.
    private func walk(_ entry: RemoteEntry, storage: UInt32, hooks: MTPTransferHooks, visit: (RemoteEntry) throws -> Void) throws {
        if hooks.isCancelled() { throw DeviceError.cancelled }
        guard !Self.disallowedNames.contains(entry.file.name) else { return }

        try visit(entry)
        guard entry.file.isFolder else { return }

        for child in try contents(of: entry.file, storage: storage) {
            try walk(RemoteEntry(file: child, localURL: entry.localURL.appendingPathComponent(child.name)), storage: storage, hooks: hooks, visit: visit)
        }
    }

    /// Creates a folder on the Mac, or fetches one file into it.
    private func fetch(_ entry: RemoteEntry, reporter: inout ProgressReporter, hooks: MTPTransferHooks) throws {
        if hooks.isCancelled() { throw DeviceError.cancelled }
        let fileManager = FileManager.default

        if entry.file.isFolder {
            do {
                try fileManager.createDirectory(at: entry.localURL, withIntermediateDirectories: true)
            } catch {
                throw localError(error, path: entry.localURL.path)
            }
            return
        }

        let writer: FileHandle
        do {
            try fileManager.createDirectory(at: entry.localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fileManager.createFile(atPath: entry.localURL.path, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            writer = try FileHandle(forWritingTo: entry.localURL)
        } catch {
            throw localError(error, path: entry.localURL.path)
        }

        reporter.begin(name: entry.file.name, path: entry.file.path, size: entry.file.size)
        do {
            var reporterCopy = reporter
            defer { reporter = reporterCopy }
            try session.getObject(
                entry.file.handle,
                into: { try writer.write(contentsOf: $0) },
                progress: { received in
                    reporterCopy.update(fileBytes: received)
                    if hooks.isCancelled(), received < entry.file.size { throw MTPError.cancelled }
                }
            )
            try writer.close()
        } catch {
            try? writer.close()
            // half a file is worse than none
            try? fileManager.removeItem(at: entry.localURL)
            try abandon(error, or: .fileTransfer) {}
        }

        if let modified = entry.file.modified {
            try? fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: entry.localURL.path)
        }
        reporter.update(fileBytes: entry.file.size)
        reporter.completeFile()
    }

    // MARK: Errors

    /// Deals with a transfer of one object that did not finish, and throws what the app should hear.
    ///
    /// Unless the device itself ended the transaction, it is still waiting for
    /// (or still sending) the rest of the object and has to be told to stop.
    private func abandon(_ error: any Error, or code: DeviceError.Code, cleanUp: () -> Void) throws -> Never {
        let endedByDevice = (error as? MTPError)?.responseCode != nil
        var sessionSurvived = !session.isBroken

        if !endedByDevice, !session.isBroken {
            sessionSurvived = session.cancelCurrentTransaction()
        }
        if sessionSurvived {
            cleanUp()
        }

        if case MTPError.cancelled = error {
            throw DeviceError(code: .transferCancelled, detail: "the transfer was cancelled", sessionReset: !sessionSurvived)
        }
        var failure = (error as? MTPError).map { deviceError($0, or: code) } ?? localError(error, path: "")
        failure.sessionReset = failure.sessionReset || !sessionSurvived
        throw failure
    }

    /// Puts an engine error into the app's terms. `code` says what was being attempted.
    private func deviceError(_ error: any Error, or code: DeviceError.Code) -> DeviceError {
        if let error = error as? DeviceError { return error }

        guard let error = error as? MTPError else {
            if error is MTPCodingError {
                return DeviceError(code: code, detail: "the device sent data that makes no sense", sessionReset: session.isBroken)
            }
            return DeviceError(code: code, detail: "\(error)", sessionReset: session.isBroken)
        }

        switch error {
        case .response(let response, _):
            let specific: DeviceError.Code? = switch response {
            case .storeFull: .storageFull
            case .storeNotAvailable: .noStorage
            case .accessDenied: .filePermission
            case .sessionNotOpen: .deviceChanged
            default: nil
            }
            return DeviceError(code: specific ?? code, detail: error.description)
        case .transport(let transport):
            let gone = transport.kind == .disconnected
            return DeviceError(code: gone ? .deviceChanged : code, detail: error.description, sessionReset: true)
        case .protocolViolation:
            return DeviceError(code: code, detail: error.description, sessionReset: true)
        case .noDevice:
            return DeviceError(code: .mtpDetectFailed, detail: error.description)
        case .multipleDevices:
            return DeviceError(code: .multipleDevice, detail: error.description)
        case .cancelled:
            return DeviceError(code: .transferCancelled, detail: error.description)
        }
    }

    private func localError(_ error: any Error, path: String) -> DeviceError {
        if let error = error as? DeviceError { return error }

        let local = LocalFileError(error, path: path)
        let code: DeviceError.Code = switch local.kind {
        case .permissionDenied: .filePermission
        case .notFound: .invalidPath
        case .other: .localFileRead
        }
        return DeviceError(code: code, detail: "\(path): \(local.detail)")
    }
}

/// Keeps the running totals of a transfer and passes them on at a readable pace.
private struct ProgressReporter {
    var progress = TransferProgress()
    let emit: (TransferEvent) -> Void

    private var bytesBeforeCurrentFile: Int64 = 0
    private var lastEmit = Date.distantPast

    init(emit: @escaping (TransferEvent) -> Void) {
        self.emit = emit
    }

    mutating func begin(name: String, path: String, size: Int64) {
        progress.currentName = name
        progress.currentPath = path
        progress.fileBytesDone = 0
        progress.fileBytesTotal = size
        bytesBeforeCurrentFile = progress.bytesDone
        send(force: true)
    }

    mutating func update(fileBytes: Int64) {
        progress.fileBytesDone = fileBytes
        progress.bytesDone = bytesBeforeCurrentFile + fileBytes
        send(force: false)
    }

    mutating func completeFile() {
        progress.filesDone += 1
        progress.fileBytesDone = progress.fileBytesTotal
        progress.bytesDone = bytesBeforeCurrentFile + progress.fileBytesTotal
        send(force: true)
    }

    mutating func finish() {
        progress.isCompleted = true
        send(force: true)
    }

    private mutating func send(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) >= 0.1 else { return }
        lastEmit = now
        emit(.progress(progress))
    }
}
