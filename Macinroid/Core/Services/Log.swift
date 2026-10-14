import Foundation
import os

/// Writes to the unified log and to a plain-text file that the user can attach
/// to a problem report.
enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.macinroid", category: "app")
    private static let file = LogFile()

    /// `~/Library/Logs/Macinroid/Macinroid.log`
    static var fileURL: URL { file.url }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        file.append("INFO ", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        file.append("ERROR", message)
    }

    /// The most recent part of the log file.
    static func recentEntries(maxBytes: Int = 256 << 10) -> String {
        file.tail(maxBytes: maxBytes)
    }

    private final class LogFile: @unchecked Sendable {
        let url: URL
        private let queue = DispatchQueue(label: "com.macinroid.log", qos: .utility)
        private let maxSize = 2 << 20

        init() {
            let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/Macinroid", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("Macinroid.log")
        }

        func append(_ level: String, _ message: String) {
            let timestamp = Date()
            queue.async { [self] in
                // keep the home folder out of anything the user may send on
                let text = message.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                let line = "\(timestamp.formatted(.iso8601)) \(level) \(text)\n"

                rotateIfNeeded()
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(line.utf8))
                } else {
                    try? Data(line.utf8).write(to: url)
                }
            }
        }

        func tail(maxBytes: Int) -> String {
            queue.sync {
                guard let data = try? Data(contentsOf: url) else { return "" }
                return String(decoding: data.suffix(maxBytes), as: UTF8.self)
            }
        }

        private func rotateIfNeeded() {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxSize else { return }
            let previous = url.deletingPathExtension().appendingPathExtension("previous.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
    }
}
