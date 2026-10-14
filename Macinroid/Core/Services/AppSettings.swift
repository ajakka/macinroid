import AppKit
import Observation

enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum ViewMode: String, CaseIterable, Identifiable, Sendable {
    case list, grid

    var id: String { rawValue }

    var title: String { self == .list ? "List" : "Icons" }
    var symbolName: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

/// The user's preferences, kept in the app's defaults.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    // General
    var appearance: AppearanceMode { didSet { save(appearance.rawValue, .appearance); applyAppearance() } }
    /// Connect to a phone as soon as it is plugged in, and notice when it is unplugged.
    var connectAutomatically: Bool { didSet { save(connectAutomatically, .connectAutomatically) } }

    // File browser
    var showHiddenFilesOnMac: Bool { didSet { save(showHiddenFilesOnMac, .showHiddenFilesOnMac) } }
    var showHiddenFilesOnPhone: Bool { didSet { save(showHiddenFilesOnPhone, .showHiddenFilesOnPhone) } }
    var macViewMode: ViewMode { didSet { save(macViewMode.rawValue, .macViewMode) } }
    var phoneViewMode: ViewMode { didSet { save(phoneViewMode.rawValue, .phoneViewMode) } }
    var macSort: FileSort { didSet { save(macSort, .macSort) } }
    var phoneSort: FileSort { didSet { save(phoneSort, .phoneSort) } }
    var foldersFirst: Bool { didSet { save(foldersFirst, .foldersFirst) } }
    var showStatusBar: Bool { didSet { save(showStatusBar, .showStatusBar) } }
    /// Show pictures of photos and other files in place of their icons.
    var showIconPreviews: Bool { didSet { save(showIconPreviews, .showIconPreviews) } }
    var showMacPane: Bool { didSet { save(showMacPane, .showMacPane) } }
    var macPaneOnLeft: Bool { didSet { save(macPaneOnLeft, .macPaneOnLeft) } }

    // Transfers: count the files first so that overall progress can be shown
    var showOverallProgressToPhone: Bool { didSet { save(showOverallProgressToPhone, .showOverallProgressToPhone) } }
    var showOverallProgressToMac: Bool { didSet { save(showOverallProgressToMac, .showOverallProgressToMac) } }
    var notifyWhenTransfersFinish: Bool { didSet { save(notifyWhenTransfersFinish, .notifyWhenTransfersFinish) } }
    /// Where the Download command saves items from the phone.
    var downloadFolder: String { didSet { save(downloadFolder, .downloadFolder) } }

    // Updates
    var checkForUpdatesAutomatically: Bool { didSet { save(checkForUpdatesAutomatically, .checkForUpdatesAutomatically) } }
    var includeBetaUpdates: Bool { didSet { save(includeBetaUpdates, .includeBetaUpdates) } }

    /// The app version whose welcome window was shown last.
    var lastWelcomeVersion: String { didSet { save(lastWelcomeVersion, .lastWelcomeVersion) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        func bool(_ key: Key, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key.rawValue) as? Bool ?? fallback
        }
        func string(_ key: Key) -> String { defaults.string(forKey: key.rawValue) ?? "" }
        func sort(_ key: Key) -> FileSort {
            guard let data = defaults.data(forKey: key.rawValue),
                  let sort = try? JSONDecoder().decode(FileSort.self, from: data) else { return FileSort() }
            return sort
        }

        appearance = AppearanceMode(rawValue: string(.appearance)) ?? .system
        connectAutomatically = bool(.connectAutomatically, true)
        showHiddenFilesOnMac = bool(.showHiddenFilesOnMac, false)
        showHiddenFilesOnPhone = bool(.showHiddenFilesOnPhone, false)
        macViewMode = ViewMode(rawValue: string(.macViewMode)) ?? .list
        phoneViewMode = ViewMode(rawValue: string(.phoneViewMode)) ?? .list
        macSort = sort(.macSort)
        phoneSort = sort(.phoneSort)
        foldersFirst = bool(.foldersFirst, true)
        showStatusBar = bool(.showStatusBar, true)
        showIconPreviews = bool(.showIconPreviews, true)
        // the phone alone by default; files go to and from Finder
        showMacPane = bool(.showMacPane, false)
        macPaneOnLeft = bool(.macPaneOnLeft, true)
        showOverallProgressToPhone = bool(.showOverallProgressToPhone, true)
        showOverallProgressToMac = bool(.showOverallProgressToMac, true)
        notifyWhenTransfersFinish = bool(.notifyWhenTransfersFinish, true)
        let savedFolder = string(.downloadFolder)
        downloadFolder = savedFolder.isEmpty ? Self.defaultDownloadFolder : savedFolder
        checkForUpdatesAutomatically = bool(.checkForUpdatesAutomatically, true)
        includeBetaUpdates = bool(.includeBetaUpdates, false)
        lastWelcomeVersion = string(.lastWelcomeVersion)
    }

    static var defaultDownloadFolder: String {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Downloads"
    }

    /// The download folder's name as Finder shows it.
    var downloadFolderName: String {
        FileManager.default.displayName(atPath: downloadFolder)
    }

    func applyAppearance() {
        NSApp?.appearance = appearance.appearance
    }

    // MARK: Per-pane access

    func showsHiddenFiles(in pane: PaneKind) -> Bool {
        pane == .mac ? showHiddenFilesOnMac : showHiddenFilesOnPhone
    }

    func setShowsHiddenFiles(_ value: Bool, in pane: PaneKind) {
        if pane == .mac { showHiddenFilesOnMac = value } else { showHiddenFilesOnPhone = value }
    }

    func viewMode(for pane: PaneKind) -> ViewMode {
        pane == .mac ? macViewMode : phoneViewMode
    }

    func setViewMode(_ mode: ViewMode, for pane: PaneKind) {
        if pane == .mac { macViewMode = mode } else { phoneViewMode = mode }
    }

    func sort(for pane: PaneKind) -> FileSort {
        pane == .mac ? macSort : phoneSort
    }

    func setSort(_ sort: FileSort, for pane: PaneKind) {
        if pane == .mac { macSort = sort } else { phoneSort = sort }
    }

    func countsFilesFirst(for direction: TransferDirection) -> Bool {
        direction == .upload ? showOverallProgressToPhone : showOverallProgressToMac
    }

    // MARK: Storage

    private enum Key: String {
        case appearance, connectAutomatically
        case showHiddenFilesOnMac, showHiddenFilesOnPhone, macViewMode, phoneViewMode, macSort, phoneSort
        case foldersFirst, showStatusBar, showIconPreviews, showMacPane, macPaneOnLeft
        case showOverallProgressToPhone, showOverallProgressToMac, notifyWhenTransfersFinish, downloadFolder
        case checkForUpdatesAutomatically, includeBetaUpdates
        case lastWelcomeVersion
    }

    private func save(_ value: Bool, _ key: Key) { defaults.set(value, forKey: key.rawValue) }
    private func save(_ value: String, _ key: Key) { defaults.set(value, forKey: key.rawValue) }
    private func save(_ value: FileSort, _ key: Key) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key.rawValue)
    }
}
