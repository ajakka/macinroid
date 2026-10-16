import Foundation
import UniformTypeIdentifiers

/// The two sides of a transfer.
enum PaneKind: String, Sendable, CaseIterable, Codable, Identifiable {
    case mac
    case phone

    var id: String { rawValue }

    var other: PaneKind { self == .mac ? .phone : .mac }
}

/// One entry of a folder listing, on the Mac or on the phone.
struct FileItem: Identifiable, Hashable, Sendable {
    var path: String
    var name: String
    var isFolder: Bool
    /// Size in bytes. Not meaningful for folders.
    var size: Int64
    var modified: Date?
    /// Set for bundles such as apps: a directory that the Mac presents as one file.
    var isPackage = false
    /// Set for files on the phone of which the phone keeps a small picture.
    var hasThumbnail = false

    var id: String { path }

    var pathExtension: String {
        isFolder ? "" : (name as NSString).pathExtension.lowercased()
    }

    var contentType: UTType {
        if isFolder { return .folder }
        if isPackage { return UTType(filenameExtension: (name as NSString).pathExtension) ?? .package }
        return UTType(filenameExtension: pathExtension) ?? .data
    }
}

/// Helpers for the POSIX-style paths used on both sides.
enum FilePath {
    static let root = "/"

    /// Collapses repeated separators and removes a trailing one.
    static func normalize(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + parts.joined(separator: "/")
    }

    static func parent(of path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + parts.dropLast().joined(separator: "/")
    }

    static func join(_ directory: String, _ name: String) -> String {
        normalize(directory + "/" + name)
    }

    static func name(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
    }

    /// Every ancestor of `path` from the root down to `path` itself.
    static func ancestors(of path: String) -> [String] {
        var result = [root]
        var current = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + part
            result.append(current)
        }
        return result
    }

    /// Whether `path` is `ancestor` or lies inside it.
    static func isSame(_ path: String, orInside ancestor: String) -> Bool {
        let path = normalize(path), ancestor = normalize(ancestor)
        return path == ancestor || ancestor == root || path.hasPrefix(ancestor + "/")
    }
}

/// How a listing is ordered.
struct FileSort: Equatable, Sendable, Codable {
    enum Key: String, Sendable, Codable, CaseIterable, Identifiable {
        case name, modified, size, kind

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: "Name"
            case .modified: "Date Modified"
            case .size: "Size"
            case .kind: "Kind"
            }
        }
    }

    var key: Key = .name
    var ascending = true

    func sorted(_ items: [FileItem], foldersFirst: Bool) -> [FileItem] {
        let ordered = items.sorted { a, b in
            if foldersFirst, a.isFolder != b.isFolder { return a.isFolder }
            let result = compare(a, b)
            if result == .orderedSame {
                // names are unique within a folder, which keeps the order stable
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        return ordered
    }

    private func compare(_ a: FileItem, _ b: FileItem) -> ComparisonResult {
        switch key {
        case .name:
            return a.name.localizedStandardCompare(b.name)
        case .modified:
            return Self.order(a.modified ?? .distantPast, b.modified ?? .distantPast)
        case .size:
            return Self.order(a.isFolder ? -1 : a.size, b.isFolder ? -1 : b.size)
        case .kind:
            return FileKind.description(for: a).localizedStandardCompare(FileKind.description(for: b))
        }
    }

    private static func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}

/// The "Kind" shown for a file, as Finder words it.
enum FileKind {
    private static let cache = Cache()

    static func description(for item: FileItem) -> String {
        if item.isFolder { return "Folder" }
        let ext = (item.name as NSString).pathExtension.lowercased()
        return cache.value(for: ext) {
            if let description = UTType(filenameExtension: ext)?.localizedDescription {
                return description.prefix(1).uppercased() + description.dropFirst()
            }
            return ext.isEmpty ? "Document" : "\(ext.uppercased()) file"
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]

        func value(for key: String, make: () -> String) -> String {
            lock.lock()
            defer { lock.unlock() }
            if let value = values[key] { return value }
            let value = make()
            values[key] = value
            return value
        }
    }
}
