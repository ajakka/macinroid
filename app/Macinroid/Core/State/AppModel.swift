import AppKit
import Observation

/// Files that were copied and are waiting to be pasted on the other side.
struct FileClipboard: Equatable {
    var source: PaneKind
    /// The storage the items are on, when they were copied from the phone.
    var storageID: UInt32?
    var paths: [String]
}

/// What is being dragged onto a pane.
enum DragPayload: Equatable {
    /// Files on the Mac, from the Mac pane or from Finder.
    case macFiles([String])
    case phoneItems([String], storageID: UInt32)

    var source: PaneKind {
        switch self {
        case .macFiles: .mac
        case .phoneItems: .phone
        }
    }

    var paths: [String] {
        switch self {
        case .macFiles(let paths), .phoneItems(let paths, _): paths
        }
    }
}

/// The app's state and everything the user can do with it.
@MainActor
@Observable
final class AppModel {
    enum Sheet: Identifiable, Equatable {
        case newFolder(PaneKind)
        case rename(PaneKind, FileItem)
        case goToFolder(PaneKind)
        case deviceInfo

        var id: String {
            switch self {
            case .newFolder(let pane): "newFolder-\(pane.rawValue)"
            case .rename(let pane, let item): "rename-\(pane.rawValue)-\(item.id)"
            case .goToFolder(let pane): "goToFolder-\(pane.rawValue)"
            case .deviceInfo: "deviceInfo"
            }
        }
    }

    let settings: AppSettings
    let session: DeviceSession
    let transfers: TransferCoordinator
    let mac: BrowserModel
    let phone: BrowserModel

    /// How far copied phone items are on their way to the system clipboard.
    enum FinderClipboard: Equatable {
        case empty
        /// The items are being fetched from the phone.
        case preparing
        /// Copies of the items are on the system clipboard, for pasting in Finder.
        case ready
    }

    /// Something worth telling the user in passing, such as where a download went.
    struct Notice: Equatable {
        var text: String
        /// A file or folder to show in Finder.
        var revealPath: String?
    }

    /// The pane that keyboard commands and the toolbar act on.
    var activePane: PaneKind
    private(set) var clipboard: FileClipboard?
    private(set) var finderClipboard = FinderClipboard.empty
    private(set) var notice: Notice?
    var sheet: Sheet?

    /// Folders at the top of the phone's storage that deserve a shortcut.
    private(set) var phoneShortcuts: [String] = []
    /// Volumes other than the startup disk.
    private(set) var volumes: [(name: String, path: String, isEjectable: Bool)] = []

    @ObservationIgnored weak var window: NSWindow?
    /// Answers questions in place of an alert; tests use it to stand in for the user.
    @ObservationIgnored var alertHandler: (@MainActor (_ title: String, _ message: String, _ buttons: [String]) async -> Int)?
    @ObservationIgnored let quickLook = QuickLookController()
    /// Copies of phone files, for Quick Look and for opening them.
    let phoneFiles: PhoneFileCache
    @ObservationIgnored let phoneThumbnails: PhoneThumbnails
    /// The phone files being fetched for Quick Look, by path.
    @ObservationIgnored private var previewFetches: [String: Task<Void, Never>] = [:]

    /// The system clipboard; tests substitute one of their own.
    @ObservationIgnored var pasteboard = NSPasteboard.general

    @ObservationIgnored private let usbMonitor = USBMonitor()
    @ObservationIgnored private var pasteboardChangeCount = -1
    /// The temporary copies that are on the system clipboard.
    @ObservationIgnored private var clipboardFiles: [URL] = []
    /// The folders holding them, and the transfers still filling some of them.
    @ObservationIgnored private var clipboardFolders: [URL] = []
    @ObservationIgnored private var clipboardJobs: [UInt64: URL] = [:]
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var afterTransfer: [UInt64: @MainActor (TransferJob) -> Void] = [:]
    @ObservationIgnored private var volumeObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var hasStarted = false

    private static let wellKnownPhoneFolders = ["DCIM", "Pictures", "Download", "Documents", "Movies", "Music"]

    init(settings: AppSettings, backend: any DeviceBackend) {
        self.settings = settings
        activePane = settings.showMacPane ? .mac : .phone
        session = DeviceSession(backend: backend)
        transfers = TransferCoordinator(backend: backend)
        phoneFiles = PhoneFileCache(backend: backend, folder: Self.scratchRoot.appendingPathComponent("Previews", isDirectory: true))
        phoneThumbnails = PhoneThumbnails(backend: backend, files: phoneFiles)

        mac = BrowserModel(kind: .mac, path: LocalFileSystem.homePath, settings: settings) { path, includeHidden in
            try await Task.detached(priority: .userInitiated) {
                try LocalFileSystem.list(path: path, includeHidden: includeHidden)
            }.value
        }

        let session = session
        phone = BrowserModel(kind: .phone, path: FilePath.root, settings: settings) { path, includeHidden in
            guard let storage = await session.selectedStorageID, await session.isConnected else {
                throw DeviceError.notConnected
            }
            do {
                return try await backend.list(storage: storage, path: path, includeHidden: includeHidden)
            } catch {
                await session.noteFailure(DeviceError(error))
                throw error
            }
        }

        session.onConnected = { [weak self] in await self?.phoneDidConnect() }
        transfers.onJobEnded = { [weak self] job in await self?.transferDidEnd(job) }
        transfers.beforeEachJob = { [weak self] in await self?.makeWayForTransfer() }

        phoneFiles.onSessionEnded = { [weak self] error in await self?.recover(from: error) }
        // as when listing a folder fails
        phoneThumbnails.onSessionEnded = { [weak self] error in self?.session.noteFailure(error) }
        phoneThumbnails.isEnabled = { [weak self] in
            guard let self else { return false }
            return settings.showIconPreviews && isAvailable(.phone)
        }
        quickLook.onShowItem = { [weak self] item in self?.loadPreview(of: item) }
        quickLook.onClose = { [weak self] in self?.stopLoadingPreviews() }
    }

    // MARK: Lifecycle

    /// Loads the first listings and starts looking for a phone.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        settings.applyAppearance()
        refreshVolumes()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }

        // another app may have replaced what Macinroid put on the clipboard
        volumeObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forgetClipboardIfReplaced() }
        })

        usbMonitor.onEvent = { [weak self] event in self?.handle(event) }
        usbMonitor.start()

        // leftovers of earlier sessions: opened files and clipboard copies
        try? FileManager.default.removeItem(at: Self.scratchRoot)

        if settings.showMacPane {
            Task { await mac.reload() }
        }
        Task { await session.connect() }
    }

    /// Temporary copies of phone files, for opening them and for the clipboard.
    private static let scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Macinroid", isDirectory: true)

    private static func makeScratchFolder(_ purpose: String) -> URL {
        let folder = scratchRoot.appendingPathComponent("\(purpose)/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Set when the app has been told to quit, so that nothing new is started.
    @ObservationIgnored var isQuitting = false

    /// Closes the session with the phone; called when the app quits.
    func shutDown() async {
        usbMonitor.stop()
        await session.disconnect()
    }

    private func handle(_ event: USBMonitor.Event) {
        guard settings.connectAutomatically else { return }

        switch event {
        case .attached:
            if !session.isConnected, !transfers.isBusy {
                session.connectPersistently()
            }
        case .detached(let device):
            Task { await session.deviceWasDetached(serialNumber: device.serialNumber) }
        }
    }

    private func refreshVolumes() {
        volumes = LocalFileSystem.mountedVolumes()
    }

    // MARK: Panes

    func browser(_ pane: PaneKind) -> BrowserModel {
        pane == .mac ? mac : phone
    }

    var activeBrowser: BrowserModel { browser(activePane) }

    /// Whether the pane can be browsed right now. The phone does one thing at
    /// a time, so its pane is out of reach while files are being copied.
    func isAvailable(_ pane: PaneKind) -> Bool {
        pane == .mac || (session.isConnected && !transfers.hasWork)
    }

    func activate(_ pane: PaneKind) {
        guard pane == .phone || settings.showMacPane else { return }
        activePane = pane
    }

    func switchPane() {
        guard settings.showMacPane else { return }
        activePane = activePane.other
    }

    /// The name shown for a side: the phone's model, or "Mac".
    func title(for pane: PaneKind) -> String {
        pane == .mac ? "Mac" : session.deviceName
    }

    // MARK: Navigation

    func navigate(_ pane: PaneKind, to path: String) {
        activate(pane)
        Task { await browser(pane).navigate(to: path) }
    }

    func goUp(_ pane: PaneKind) {
        Task { await browser(pane).goUp() }
    }

    func goBack(_ pane: PaneKind) {
        Task { await browser(pane).goBack() }
    }

    func goForward(_ pane: PaneKind) {
        Task { await browser(pane).goForward() }
    }

    /// Lists the pane again. For the phone this is also how a connection is made.
    func refresh(_ pane: PaneKind) {
        Task {
            switch pane {
            case .mac:
                refreshVolumes()
                await mac.reload()
            case .phone:
                if session.isConnected {
                    await phone.reload()
                    await session.refreshStorages()
                } else {
                    session.stopRetrying()
                    await session.connect()
                }
            }
        }
    }

    func open(_ item: FileItem, in pane: PaneKind) {
        if item.isFolder {
            navigate(pane, to: item.path)
        } else if pane == .mac {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        } else {
            openOnMac(phoneItems: [item])
        }
    }

    func openSelection(in pane: PaneKind) {
        let items = browser(pane).selectedItems
        if items.count == 1, let item = items.first {
            open(item, in: pane)
        } else if pane == .mac {
            for item in items where !item.isFolder {
                NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            }
        } else {
            openOnMac(phoneItems: items.filter { !$0.isFolder })
        }
    }

    func showInFinder(_ items: [FileItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(fileURLWithPath: $0.path) })
    }

    func selectStorage(_ id: UInt32) {
        guard id != session.selectedStorageID else { return }
        session.selectStorage(id)
        phoneThumbnails.cancelAll()
        phone.reset()
        phoneShortcuts = []
        activate(.phone)
        Task { await phone.reload() }
    }

    func setShowsHiddenFiles(_ value: Bool, in pane: PaneKind) {
        settings.setShowsHiddenFiles(value, in: pane)
        Task { await browser(pane).reload() }
    }

    func setShowsIconPreviews(_ value: Bool) {
        settings.showIconPreviews = value
        if !value { phoneThumbnails.cancelAll() }
        // draws every icon again
        mac.rebuild()
        phone.rebuild()
    }

    /// Re-sorts both panes after a setting that affects the order changed.
    func sortingPreferencesChanged() {
        mac.rebuild()
        phone.rebuild()
    }

    private func phoneDidConnect() async {
        if session.isSameDeviceAsBefore, phone.path != FilePath.root {
            // pick up where the user was before the phone went away
            await phone.reload()
            if phone.error == nil { return }
        }
        phone.reset()
        await phone.reload()
        updatePhoneShortcuts()
    }

    private func updatePhoneShortcuts() {
        guard phone.path == FilePath.root, phone.error == nil else { return }
        let folders = Set(phone.unfilteredItems.filter(\.isFolder).map(\.name))
        phoneShortcuts = Self.wellKnownPhoneFolders.filter(folders.contains)
    }

    // MARK: Previews

    /// Asks for a picture of the file's contents to show in place of its
    /// icon. `completion` may be called at once, later, or never. Returns a
    /// ticket to cancel once the file is out of view, when there is one.
    @discardableResult
    func requestIconPreview(
        for item: FileItem, in pane: PaneKind, size: CGFloat, scale: CGFloat, completion: @escaping @MainActor (NSImage) -> Void
    ) -> PhoneThumbnails.Ticket? {
        guard settings.showIconPreviews else { return nil }
        switch pane {
        case .mac:
            FileIcons.thumbnail(for: item, size: size, scale: scale, completion: completion)
            return nil
        case .phone:
            guard let storage = session.selectedStorageID else { return nil }
            return phoneThumbnails.request(item, storage: storage, completion: completion)
        }
    }

    func canQuickLook(in pane: PaneKind) -> Bool {
        quickLook.isVisible || !previewItems(for: pane).isEmpty
    }

    /// Opens Quick Look for the selection, or closes it.
    func toggleQuickLook(in pane: PaneKind) {
        if quickLook.isVisible {
            quickLook.close()
            return
        }
        let items = previewItems(for: pane)
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }
        quickLook.toggle(items)
    }

    /// Keeps an open Quick Look panel in step with the selection.
    func selectionDidChange(in pane: PaneKind) {
        guard quickLook.isVisible, pane == activePane else { return }
        quickLook.update(previewItems(for: pane))
    }

    /// What Quick Look shows for the pane's selection. Folders on the phone are left out.
    func previewItems(for pane: PaneKind) -> [PreviewItem] {
        let selected = browser(pane).selectedItems
        switch pane {
        case .mac:
            return selected.map { PreviewItem(macFile: $0.path) }
        case .phone:
            guard isAvailable(.phone), let storage = session.selectedStorageID else { return [] }
            return selected.filter { !$0.isFolder }.map { item in
                // an item already in the panel keeps its place, and its copy
                quickLook.items.first { $0.id == item.path && $0.phoneFile?.item == item }
                    ?? PreviewItem(phoneFile: item, storage: storage, localCopy: phoneFiles.localCopy(of: item, storage: storage))
            }
        }
    }

    /// Fetches the phone file the panel has moved to, and stops fetching the ones it has left.
    private func loadPreview(of preview: PreviewItem) {
        for (path, task) in previewFetches where path != preview.id {
            task.cancel()
            previewFetches[path] = nil
        }
        guard preview.previewItemURL == nil, previewFetches[preview.id] == nil, let (item, storage) = preview.phoneFile else { return }

        previewFetches[preview.id] = Task {
            // a cancelled fetch has been taken off the list already, and may have been replaced
            defer { if !Task.isCancelled { previewFetches[preview.id] = nil } }
            do {
                preview.previewItemURL = try await phoneFiles.fetch(item, storage: storage, urgent: true)
                quickLook.itemDidLoad(preview)
            } catch {
                let error = DeviceError(error)
                guard !error.isCancellation, !Task.isCancelled else { return }
                if quickLook.currentItem === preview {
                    quickLook.close()
                    present(error, doing: "“\(item.name)” can’t be shown.")
                }
            }
        }
    }

    private func stopLoadingPreviews() {
        previewFetches.values.forEach { $0.cancel() }
        previewFetches = [:]
    }

    /// Stops everything that reads from the phone in the background, before
    /// a transfer takes the connection for itself.
    private func makeWayForTransfer() async {
        if quickLook.isShowingPhoneFiles {
            quickLook.close()
        }
        stopLoadingPreviews()
        phoneThumbnails.cancelAll()
        await phoneFiles.stopAll()
    }

    /// Picks up after a request that ended the session. Returns whether a new session was opened.
    @discardableResult
    private func recover(from error: DeviceError) async -> Bool {
        guard error.endsSession else { return false }
        if error.isCancellation {
            // Stopping midway leaves the session unusable, but the phone
            // is still there: open a new one, unless the app is on its way out.
            guard !isQuitting else { return false }
            await session.reconnect()
            return session.isConnected
        }
        // The phone is gone. Say so at once, and pick it up again if it comes back.
        session.noteFailure(error)
        if settings.connectAutomatically {
            session.connectPersistently(attempts: 4)
        }
        return false
    }

    // MARK: New folder, rename, delete

    func requestNewFolder(in pane: PaneKind) {
        guard isAvailable(pane), browser(pane).error == nil else { return }
        sheet = .newFolder(pane)
    }

    func requestRename(in pane: PaneKind) {
        let items = browser(pane).selectedItems
        guard isAvailable(pane), items.count == 1, let item = items.first else { return }
        sheet = .rename(pane, item)
    }

    func requestGoToFolder(in pane: PaneKind) {
        guard isAvailable(pane) else { return }
        sheet = .goToFolder(pane)
    }

    /// Checks a name typed for a new folder, or for `item` when renaming.
    func problem(withName name: String, in pane: PaneKind, renaming item: FileItem? = nil) -> FileNameRule.Problem? {
        let siblings = browser(pane).unfilteredItems.map(\.name).filter { $0 != item?.name }
        return FileNameRule.validate(name, siblings: siblings, current: item?.name)
    }

    /// Returns whether the folder was created.
    func createFolder(named name: String, in pane: PaneKind) async -> Bool {
        let browser = browser(pane)
        let path = FilePath.join(browser.path, name)

        do {
            switch pane {
            case .mac:
                try await Task.detached { try LocalFileSystem.makeDirectory(path: path) }.value
            case .phone:
                try await session.backend.makeDirectory(storage: try requireStorage(), path: path)
            }
            await browser.reload(selecting: [name])
            if pane == .phone { updatePhoneShortcuts() }
            return true
        } catch {
            present(error, doing: "The folder “\(name)” couldn’t be created.")
            return false
        }
    }

    /// Returns whether the item was renamed.
    func rename(_ item: FileItem, to newName: String, in pane: PaneKind) async -> Bool {
        guard newName != item.name else { return true }

        do {
            switch pane {
            case .mac:
                try await Task.detached { try LocalFileSystem.rename(path: item.path, to: newName) }.value
            case .phone:
                try await session.backend.rename(storage: try requireStorage(), path: item.path, newName: newName)
            }
            await browser(pane).reload(selecting: [newName])
            return true
        } catch {
            present(error, doing: "“\(item.name)” couldn’t be renamed.")
            return false
        }
    }

    /// Moves the selection to the Trash on the Mac; deletes it, after asking, on the phone.
    func deleteSelection(in pane: PaneKind) {
        let items = browser(pane).selectedItems
        guard isAvailable(pane), !items.isEmpty else { return }

        Task {
            let paths = items.map(\.path)
            do {
                switch pane {
                case .mac:
                    try await Task.detached { try LocalFileSystem.trash(paths: paths) }.value
                    await mac.reload()

                case .phone:
                    let subject = items.count == 1 ? "“\(items[0].name)”" : "\(items.count.formatted()) items"
                    let confirmed = await confirm(
                        title: "Are you sure you want to delete \(subject) from \(session.deviceName)?",
                        message: "\(items.count == 1 ? "This item" : "These items") will be deleted immediately. You can’t undo this action.",
                        action: "Delete",
                        isDestructive: true
                    )
                    guard confirmed else { return }
                    try await session.backend.delete(storage: try requireStorage(), paths: paths)
                    await phone.reload()
                    await session.refreshStorages()
                    updatePhoneShortcuts()
                }
            } catch {
                await browser(pane).reload()
                present(error, doing: items.count == 1 ? "“\(items[0].name)” couldn’t be deleted." : "Some items couldn’t be deleted.")
            }
        }
    }

    private func requireStorage() throws -> UInt32 {
        guard session.isConnected, let storage = session.selectedStorageID else { throw DeviceError.notConnected }
        return storage
    }

    // MARK: Clipboard

    func canCopy(in pane: PaneKind) -> Bool {
        isAvailable(pane) && !browser(pane).selection.isEmpty
    }

    /// Puts the selection on the clipboard, replacing what was there.
    func copy(in pane: PaneKind) {
        guard canCopy(in: pane) else { return }
        let items = browser(pane).selectedItems

        discardClipboardCopies()
        setClipboard(FileClipboard(source: pane, storageID: storageID(for: pane), paths: items.map(\.path)))
        fetchForFinder(items)
    }

    /// Adds the selection to the clipboard, so that items from several
    /// folders can be pasted in one go.
    func addToClipboard(in pane: PaneKind) {
        guard canCopy(in: pane) else { return }

        guard var clipboard, clipboard.source == pane, clipboard.storageID == storageID(for: pane) else {
            copy(in: pane)
            return
        }
        let added = browser(pane).selectedItems.filter { !clipboard.paths.contains($0.path) }
        clipboard.paths.append(contentsOf: added.map(\.path))
        setClipboard(clipboard)
        fetchForFinder(added)
    }

    /// Finder can paste files, but not files that are still on a phone. So
    /// when the phone has the window to itself, copying fetches the items to
    /// a temporary folder and puts those copies on the system clipboard.
    private func fetchForFinder(_ items: [FileItem]) {
        guard !settings.showMacPane, let clipboard, clipboard.source == .phone,
              let storage = clipboard.storageID, !items.isEmpty
        else { return }

        // a folder per batch: items from different places may share a name
        let folder = Self.makeScratchFolder("Clipboard")
        clipboardFolders.append(folder)
        finderClipboard = .preparing

        let id = download(items.map(\.path), storageID: storage, to: folder.path, targetName: "the clipboard") { [weak self] succeeded in
            guard let self else { return }
            clipboardJobs = clipboardJobs.filter { $0.value != folder }

            // the user has copied something else in the meantime
            guard clipboardFolders.contains(folder) else {
                try? FileManager.default.removeItem(at: folder)
                return
            }
            guard succeeded else {
                discardClipboardCopies()
                self.clipboard = nil
                return
            }

            clipboardFiles += items.map { folder.appendingPathComponent($0.name) }
            pasteboard.clearContents()
            pasteboard.writeObjects(clipboardFiles.map { $0 as NSURL })
            pasteboardChangeCount = pasteboard.changeCount
            if clipboardJobs.isEmpty { finderClipboard = .ready }
        }
        if let id { clipboardJobs[id] = folder }
    }

    /// Drops the temporary copies made for the clipboard.
    private func discardClipboardCopies() {
        for folder in clipboardFolders {
            if let job = clipboardJobs.first(where: { $0.value == folder })?.key {
                // still being filled; it is removed once the transfer has stopped
                transfers.cancel(job)
            } else {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        clipboardFolders = []
        clipboardFiles = []
        finderClipboard = .empty
    }

    private func forgetClipboardIfReplaced() {
        guard finderClipboard == .ready, pasteboard.changeCount != pasteboardChangeCount else { return }
        discardClipboardCopies()
        clipboard = nil
    }

    func canPaste(in pane: PaneKind) -> Bool {
        guard session.isConnected, isAvailable(pane), browser(pane).error == nil else { return false }
        if let clipboard, clipboard.source != pane { return true }
        return pane == .phone && !filesOnSystemPasteboard().isEmpty
    }

    /// Copies what is on the clipboard into the pane's current folder.
    func paste(in pane: PaneKind) {
        guard canPaste(in: pane) else {
            NSSound.beep()
            return
        }

        let destination = browser(pane).path
        // files copied in Finder after the last copy made here take precedence
        let fromFinder = pane == .phone && pasteboard.changeCount != pasteboardChangeCount ? filesOnSystemPasteboard() : []

        if !fromFinder.isEmpty {
            startTransfer(.upload, sources: fromFinder, destination: destination)
        } else if let clipboard, clipboard.source != pane {
            startTransfer(pane == .phone ? .upload : .download, sources: clipboard.paths, destination: destination, storageID: clipboard.storageID)
            self.clipboard = nil
        } else {
            startTransfer(.upload, sources: filesOnSystemPasteboard(), destination: destination)
        }
    }

    private func setClipboard(_ clipboard: FileClipboard) {
        self.clipboard = clipboard

        // files on the Mac also go to the system pasteboard, for Finder and other apps
        if clipboard.source == .mac {
            pasteboard.clearContents()
            pasteboard.writeObjects(clipboard.paths.map { URL(fileURLWithPath: $0) as NSURL })
        }
        pasteboardChangeCount = pasteboard.changeCount
    }

    private func filesOnSystemPasteboard() -> [String] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).map(\.path)
    }

    private func storageID(for pane: PaneKind) -> UInt32? {
        pane == .phone ? session.selectedStorageID : nil
    }

    // MARK: Transfers

    func canCopyToOtherPane(from pane: PaneKind) -> Bool {
        session.isConnected && canCopy(in: pane) && browser(pane.other).error == nil
    }

    /// Copies the selection into the folder the other pane is showing.
    func copySelectionToOtherPane(from pane: PaneKind) {
        guard canCopyToOtherPane(from: pane) else { return }
        startTransfer(
            pane == .mac ? .upload : .download,
            sources: browser(pane).selectedItems.map(\.path),
            destination: browser(pane.other).path
        )
    }

    func canDrop(_ payload: DragPayload, on pane: PaneKind) -> Bool {
        payload.source != pane && session.isConnected && isAvailable(pane) && browser(pane).error == nil
    }

    /// Copies dragged items into `folder`, or into the pane's current folder.
    @discardableResult
    func drop(_ payload: DragPayload, on pane: PaneKind, into folder: String? = nil) -> Bool {
        guard canDrop(payload, on: pane), !payload.paths.isEmpty else { return false }
        activate(pane)

        switch payload {
        case .macFiles(let paths):
            startTransfer(.upload, sources: paths, destination: folder ?? phone.path)
        case .phoneItems(let paths, let storageID):
            startTransfer(.download, sources: paths, destination: folder ?? mac.path, storageID: storageID)
        }
        return true
    }

    /// Copies files handed to the app from outside — dropped on its Dock icon,
    /// or opened with it — into the folder the phone pane is showing.
    func upload(filesFromOutside paths: [String]) {
        guard !paths.isEmpty else { return }

        Task {
            // the files may be what launched the app; give the phone a moment
            if !session.isConnected {
                await session.connect()
            }
            guard session.isConnected, phone.error == nil else {
                await alert(
                    title: "Connect your phone to copy \(paths.count == 1 ? "this item" : "these items") to it.",
                    message: DeviceError.notConnected.suggestion
                )
                return
            }
            activate(.phone)
            startTransfer(.upload, sources: paths, destination: phone.path)
        }
    }

    func canDownloadSelection() -> Bool {
        session.isConnected && canCopy(in: .phone)
    }

    /// Saves the phone pane's selection into `folder`, or into the download folder.
    func downloadSelection(to folder: String? = nil) {
        guard canDownloadSelection() else { return }
        let destination = folder ?? settings.downloadFolder
        startTransfer(
            .download, sources: phone.selectedItems.map(\.path), destination: destination,
            targetName: "“\(FileManager.default.displayName(atPath: destination))”"
        )
    }

    /// Asks where to save the phone pane's selection, and remembers the answer.
    func chooseFolderAndDownloadSelection() {
        guard canDownloadSelection() else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: settings.downloadFolder, isDirectory: true)
        panel.prompt = "Download"
        panel.message = "Choose where to save the selected items."

        Task {
            guard await run(panel) == .OK, let folder = panel.url?.path else { return }
            settings.downloadFolder = folder
            downloadSelection(to: folder)
        }
    }

    func canUpload() -> Bool {
        session.isConnected && phone.error == nil
    }

    /// Asks for files and folders on the Mac and copies them to the folder the phone pane is showing.
    func chooseFilesToUpload() {
        guard canUpload() else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files and folders to copy to \(session.deviceName)."

        let destination = phone.path
        Task {
            guard await run(panel) == .OK else { return }
            startTransfer(.upload, sources: panel.urls.map(\.path), destination: destination)
        }
    }

    private func run(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        if let window = window ?? NSApp.mainWindow, window.isVisible {
            return await panel.beginSheetModal(for: window)
        }
        return panel.runModal()
    }

    /// Downloads phone items into any folder on the Mac, as when they are
    /// dragged to Finder. `completion` is called once the transfer is over.
    /// Returns the transfer's id, or nil if it could not be started.
    @discardableResult
    func download(
        _ paths: [String], storageID: UInt32, to folder: String, targetName: String? = nil,
        completion: @escaping @MainActor (Bool) -> Void
    ) -> UInt64? {
        guard session.isConnected else {
            completion(false)
            return nil
        }
        let request = TransferRequest(
            direction: .download, storageID: storageID, sources: paths, destination: folder,
            countFirst: settings.countsFilesFirst(for: .download)
        )
        afterTransfer[request.id] = { completion($0.phase == .finished) }
        transfers.enqueue(request, deviceName: session.deviceName, targetName: targetName)
        return request.id
    }

    /// Fetches files from the phone into a temporary folder and opens them.
    private func openOnMac(phoneItems items: [FileItem]) {
        guard !items.isEmpty, let storage = session.selectedStorageID else { return }

        let folder = Self.makeScratchFolder("Opened")

        // files seen in Quick Look are on the Mac already; a clone of the
        // copy can be changed without changing what Quick Look shows
        let copies = items.compactMap { phoneFiles.localCopy(of: $0, storage: storage) }
        if copies.count == items.count {
            for copy in copies {
                let opened = folder.appendingPathComponent(copy.lastPathComponent)
                if (try? FileManager.default.copyItem(at: copy, to: opened)) != nil {
                    NSWorkspace.shared.open(opened)
                }
            }
            return
        }


        download(items.map(\.path), storageID: storage, to: folder.path) { succeeded in
            guard succeeded else { return }
            for item in items {
                NSWorkspace.shared.open(folder.appendingPathComponent(item.name))
            }
        }
    }

    private func startTransfer(
        _ direction: TransferDirection, sources: [String], destination: String,
        storageID: UInt32? = nil, targetName: String? = nil
    ) {
        guard !sources.isEmpty else { return }
        guard session.isConnected, let storage = storageID ?? session.selectedStorageID else {
            present(DeviceError.notConnected, doing: "The items couldn’t be copied.")
            return
        }

        if direction == .upload {
            let unusable = sources.map(FilePath.name(of:)).filter { $0.contains(":") || $0.contains("\\") }
            if let name = unusable.first {
                Task {
                    await alert(
                        title: unusable.count == 1 ? "“\(name)” can’t be copied to the phone." : "\(unusable.count) items can’t be copied to the phone.",
                        message: "Names that contain a colon or a backslash can’t be used on Android. Rename \(unusable.count == 1 ? "the item" : "the items") and try again."
                    )
                }
                return
            }
        }

        let request = TransferRequest(
            direction: direction, storageID: storage, sources: sources, destination: destination,
            countFirst: settings.countsFilesFirst(for: direction)
        )
        transfers.enqueue(request, deviceName: session.deviceName, targetName: targetName) { [weak self] request in
            await self?.resolveConflicts(for: request)
        }
    }

    /// Asks what to do about items that already exist at the destination.
    /// Returns the request to carry out, or nil to call the transfer off.
    private func resolveConflicts(for request: TransferRequest) async -> TransferRequest? {
        let targets = request.sources.map { FilePath.join(request.destination, FilePath.name(of: $0)) }

        let exists: [Bool]
        switch request.direction {
        case .download:
            exists = await Task.detached { targets.map(LocalFileSystem.exists) }.value
        case .upload:
            do {
                exists = try await session.backend.exists(storage: request.storageID, paths: targets)
            } catch {
                let error = DeviceError(error)
                session.noteFailure(error)
                present(error, doing: "The items couldn’t be copied.")
                return nil
            }
        }

        let conflicts = zip(request.sources, exists).filter(\.1).map(\.0)
        guard !conflicts.isEmpty else { return request }

        let folderName = request.destination == FilePath.root
            ? (request.direction == .upload ? session.selectedStorage?.displayName ?? session.deviceName : LocalFileSystem.startupVolumeName)
            : FilePath.name(of: request.destination)
        let single = conflicts.count == 1
        let title = single
            ? "An item named “\(FilePath.name(of: conflicts[0]))” already exists in “\(folderName)”. Do you want to replace it?"
            : "\(conflicts.count.formatted()) items already exist in “\(folderName)”. Do you want to replace them?"
        let canSkip = conflicts.count < request.sources.count

        let choice = await choose(
            title: title,
            message: "Replacing can’t be undone. Folders with the same name are merged, and files inside them that share a name are replaced.",
            buttons: ["Replace"] + (canSkip ? [single ? "Skip" : "Skip Existing"] : []) + ["Cancel"]
        )

        switch (choice, canSkip) {
        case (0, _):
            return request
        case (1, true):
            var request = request
            request.sources.removeAll(where: conflicts.contains)
            return request
        default:
            return nil
        }
    }

    private func transferDidEnd(_ job: TransferJob) async {
        let error = transfers.lastError
        var didReconnect = false

        if let error {
            didReconnect = await recover(from: error)
        }

        if let aborted = error?.abortedPath {
            // do not leave half a file behind
            switch job.direction {
            case .download:
                if let local = job.request.localPath(forDevicePath: aborted) {
                    LocalFileSystem.remove(path: local)
                }
            case .upload:
                if session.isConnected {
                    try? await session.backend.delete(storage: job.request.storageID, paths: [aborted])
                }
            }
        }

        let names = job.phase == .finished ? Set(job.request.sources.map(FilePath.name(of:))) : []
        switch job.direction {
        case .upload:
            if session.isConnected {
                if !didReconnect || phone.path == job.request.destination {
                    await phone.reload(selecting: phone.path == job.request.destination ? names : [])
                }
                await session.refreshStorages()
                updatePhoneShortcuts()
            }
        case .download:
            if FilePath.isSame(job.request.destination, orInside: mac.path) {
                await mac.reload(selecting: mac.path == job.request.destination ? names : [])
            }
        }

        let isForTheUser = afterTransfer[job.id] == nil
        afterTransfer.removeValue(forKey: job.id)?(job)
        TransferFeedback.jobEnded(job, notify: settings.notifyWhenTransfersFinish)

        if job.direction == .download, job.phase == .finished, isForTheUser {
            announceDownload(job)
        }

        if case .failed(let error) = job.phase {
            present(error, doing: "Not all items could be copied to \(job.direction == .upload ? job.deviceName : "your Mac").")
        }
    }

    /// Says where downloaded items went, since without the Mac pane nothing in the window shows it.
    private func announceDownload(_ job: TransferJob) {
        let names = job.request.sources.map(FilePath.name(of:))
        guard let first = names.first else { return }

        let folder = FileManager.default.displayName(atPath: job.request.destination)
        let firstPath = FilePath.join(job.request.destination, first)
        show(Notice(
            text: names.count == 1 ? "“\(first)” saved to “\(folder)”" : "\(Format.items(names.count)) saved to “\(folder)”",
            revealPath: firstPath
        ))

        // makes the Downloads stack in the Dock bounce, as browsers do
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.apple.DownloadFileFinished"), object: firstPath, userInfo: nil, deliverImmediately: true
        )
    }

    private func show(_ notice: Notice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { self.notice = nil }
        }
    }

    func revealNotice() {
        guard let path = notice?.revealPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        notice = nil
    }

    // MARK: Alerts

    /// Shows an error as a sheet on the main window.
    func present(_ error: any Error, doing summary: String) {
        let title: String
        var message: String

        if let error = error as? DeviceError {
            guard !error.isCancellation else { return }
            title = summary
            message = error.code == .general || error.code == .fileTransfer ? error.suggestion : "\(error.title). \(error.suggestion)"
        } else if let error = error as? LocalFileError {
            title = summary
            message = error.recoverySuggestion ?? error.detail
        } else {
            title = summary
            message = error.localizedDescription
        }
        message = message.trimmingCharacters(in: .whitespaces)

        Log.error("\(summary) \(error)")
        Task { await alert(title: title, message: message) }
    }

    func alert(title: String, message: String) async {
        _ = await choose(title: title, message: message, buttons: ["OK"])
    }

    func confirm(title: String, message: String, action: String, isDestructive: Bool = false) async -> Bool {
        await choose(title: title, message: message, buttons: [action, "Cancel"], destructiveFirst: isDestructive) == 0
    }

    /// Asks a question and returns the index of the chosen button.
    func choose(title: String, message: String, buttons: [String], destructiveFirst: Bool = false) async -> Int {
        if let alertHandler {
            return await alertHandler(title, message, buttons)
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for (index, button) in buttons.enumerated() {
            let added = alert.addButton(withTitle: button)
            if index == 0, destructiveFirst { added.hasDestructiveAction = true }
            if button == "Cancel" { added.keyEquivalent = "\u{1b}" }
        }

        let response: NSApplication.ModalResponse
        if let window = window ?? NSApp.mainWindow, window.isVisible {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}
