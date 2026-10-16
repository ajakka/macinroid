import Foundation

/// How sizes, dates, counts and durations are worded across the app.
enum Format {
    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    static func bytes(_ count: UInt64) -> String {
        bytes(Int64(clamping: count))
    }

    /// A transfer rate such as "24.5 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        "\(bytes(Int64(max(0, bytesPerSecond))))/s"
    }

    /// "Today at 14:02", "Yesterday at 09:15", "12 Mar 2026 at 18:40" — as Finder does.
    static func date(_ date: Date?) -> String {
        guard let date else { return "--" }
        return dateFormatter.string(from: date)
    }

    /// "1 item", "12 items".
    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count.formatted()) items"
    }

    /// "about 5 seconds", "about 2 minutes".
    static func remaining(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 5 { return "a few seconds" }
        let rounded = seconds < 60 ? (seconds / 5).rounded(.up) * 5 : (seconds / 60).rounded(.up) * 60
        let text = Duration.seconds(rounded).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2)
        )
        return "about \(text)"
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.rounded())).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

/// Rules for names typed by the user.
enum FileNameRule {
    /// Characters Android's storage and macOS do not both accept in a name.
    static let illegalCharacters = CharacterSet(charactersIn: "/\\?%*:|\"<>")

    enum Problem: Equatable {
        case empty
        case illegalCharacters
        case taken(String)

        var message: String {
            switch self {
            case .empty: "Enter a name."
            case .illegalCharacters: "A name can’t contain / \\ ? % * : | \" < or >."
            case .taken(let name): "The name “\(name)” is already taken. Choose a different name."
            }
        }
    }

    /// Checks `name` for a new item, or a renamed one, next to `siblings`.
    /// `current` is the name the item has now, when it is being renamed.
    static func validate(_ name: String, siblings: [String], current: String? = nil) -> Problem? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .empty }
        if name.rangeOfCharacter(from: illegalCharacters) != nil || name == "." || name == ".." { return .illegalCharacters }

        // changing only the case of letters is not a clash with itself
        let isCaseChange = current.map { $0.lowercased() == name.lowercased() } ?? false
        if !isCaseChange, siblings.contains(where: { $0.lowercased() == name.lowercased() }) {
            return .taken(name)
        }
        return nil
    }
}

/// Facts about the running app.
enum AppInfo {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Macinroid"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// "owner/name" of the GitHub repository that hosts releases and issues.
    static var repository: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "MacinroidRepository") as? String
        return value.flatMap { $0.contains("/") ? $0 : nil }
    }

    static var repositoryURL: URL? { repository.flatMap { URL(string: "https://github.com/\($0)") } }
    static var newIssueURL: URL? { repository.flatMap { URL(string: "https://github.com/\($0)/issues/new") } }

    static let openMTPURL = URL(string: "https://github.com/ganeshrvel/openmtp")!
    static let connectionHelpURL = URL(string: "https://github.com/ganeshrvel/openmtp/issues/276")!
}
