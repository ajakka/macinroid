import Foundation

/// A failure while working with files on the Mac.
struct LocalFileError: Error, Equatable, Sendable {
    enum Kind: Sendable {
        /// macOS privacy protection or file permissions refused access.
        case permissionDenied
        case notFound
        case other
    }

    var kind: Kind
    var path: String
    var detail: String

    init(_ error: any Error, path: String) {
        self.path = path
        detail = error.localizedDescription

        let error = error as NSError
        let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
            ?? (error.domain == NSPOSIXErrorDomain ? error.code : nil)

        switch (error.domain, error.code, posix) {
        case (_, _, .some(Int(EPERM))), (_, _, .some(Int(EACCES))),
             (NSCocoaErrorDomain, NSFileReadNoPermissionError, _), (NSCocoaErrorDomain, NSFileWriteNoPermissionError, _):
            kind = .permissionDenied
        case (_, _, .some(Int(ENOENT))),
             (NSCocoaErrorDomain, NSFileReadNoSuchFileError, _), (NSCocoaErrorDomain, NSFileNoSuchFileError, _):
            kind = .notFound
        default:
            kind = .other
        }
    }
}

extension LocalFileError: LocalizedError {
    var errorDescription: String? {
        switch kind {
        case .permissionDenied: "Macinroid Doesn’t Have Access"
        case .notFound: "The Item Can’t Be Found"
        case .other: "The Operation Couldn’t Be Completed"
        }
    }

    var recoverySuggestion: String? {
        switch kind {
        case .permissionDenied:
            "Allow Macinroid to access this folder in System Settings › Privacy & Security › Files and Folders."
        case .notFound:
            "It may have been moved or deleted. Refresh and try again."
        case .other:
            detail
        }
    }
}

/// File operations on the Mac. Everything here blocks and is meant to be
/// called off the main thread.
enum LocalFileSystem {
    /// Files Finder itself never shows, even with hidden files visible.
    private static let junkNames: Set<String> = [".DS_Store", ".localized", ".Trashes", ".Spotlight-V100", ".fseventsd"]

    static var homePath: String { NSHomeDirectory() }

    static func list(path: String, includeHidden: Bool) throws -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        let directory = URL(fileURLWithPath: path, isDirectory: true)

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: includeHidden ? [] : [.skipsHiddenFiles]
            )
        } catch {
            throw LocalFileError(error, path: path)
        }

        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard !junkNames.contains(name), !name.hasPrefix("._") else { return nil }

            var values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                // follow links, and leave out those that lead nowhere
                let target = url.resolvingSymlinksInPath()
                guard let resolved = try? target.resourceValues(forKeys: Set(keys)), FileManager.default.fileExists(atPath: target.path) else {
                    return nil
                }
                values = resolved
            }

            let isDirectory = values?.isDirectory ?? false
            let isPackage = values?.isPackage ?? false
            return FileItem(
                path: FilePath.join(path, name),
                name: name,
                isFolder: isDirectory && !isPackage,
                size: isDirectory ? 0 : Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate,
                isPackage: isPackage
            )
        }
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func makeDirectory(path: String) throws {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw LocalFileError(error, path: path)
        }
    }

    static func rename(path: String, to newName: String) throws {
        let destination = FilePath.join(FilePath.parent(of: path), newName)
        do {
            // a rename that only changes the case of letters needs a detour on
            // the case-insensitive file systems Macs use by default
            if path.lowercased() == destination.lowercased(), path != destination {
                let temporary = destination + ".\(UUID().uuidString).renaming"
                try FileManager.default.moveItem(atPath: path, toPath: temporary)
                try FileManager.default.moveItem(atPath: temporary, toPath: destination)
            } else {
                try FileManager.default.moveItem(atPath: path, toPath: destination)
            }
        } catch {
            throw LocalFileError(error, path: path)
        }
    }

    /// Moves the items to the Trash, from where they can be put back.
    static func trash(paths: [String]) throws {
        for path in paths {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            } catch {
                throw LocalFileError(error, path: path)
            }
        }
    }

    static func remove(path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// The name of the volume that holds `/`, as Finder shows it.
    static var startupVolumeName: String {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
    }

    /// Volumes other than the startup disk: external drives, disk images, network shares.
    static func mountedVolumes() -> [(name: String, path: String, isEjectable: Bool)] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true,
                  values.volumeIsBrowsable != false,
                  url.path.hasPrefix("/Volumes/")
            else { return nil }
            let ejectable = (values.volumeIsEjectable ?? false) || (values.volumeIsRemovable ?? false)
            return (values.volumeName ?? url.lastPathComponent, url.path, ejectable)
        }
    }
}
