import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - Icons

/// Icons for files and folders, as the system draws them.
@MainActor
enum FileIcons {
    private static let cache = NSCache<NSString, NSImage>()
    private static let thumbnails = NSCache<NSString, NSImage>()

    static func icon(for item: FileItem, in pane: PaneKind) -> NSImage {
        // On the Mac, folders and bundles have icons of their own; everything
        // else, and everything on the phone, is drawn by its type.
        let usesOwnIcon = pane == .mac && (item.isFolder || item.isPackage || item.pathExtension.isEmpty)
        let key = (usesOwnIcon ? "path:\(item.path)" : item.isFolder ? "folder" : "type:\(item.pathExtension)") as NSString

        if let cached = cache.object(forKey: key) { return cached }

        let image = usesOwnIcon
            ? NSWorkspace.shared.icon(forFile: item.path)
            : NSWorkspace.shared.icon(for: item.contentType)
        cache.setObject(image, forKey: key)
        return image
    }

    /// A preview of the contents of a file on the Mac, for files that have one.
    static func thumbnail(for item: FileItem, size: CGFloat, scale: CGFloat, completion: @escaping @MainActor (NSImage) -> Void) {
        guard !item.isFolder, item.contentType.conforms(to: .image) || item.contentType.conforms(to: .movie) || item.contentType.conforms(to: .pdf) else {
            return
        }

        let key = "\(item.path)|\(item.modified?.timeIntervalSince1970 ?? 0)"
        if let cached = thumbnails.object(forKey: key as NSString) {
            completion(cached)
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: item.path),
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            Task { @MainActor in
                thumbnails.setObject(image, forKey: key as NSString)
                completion(image)
            }
        }
    }
}

// MARK: - Drag and drop

extension NSPasteboard.PasteboardType {
    /// A file or folder on the phone, dragged from the phone pane.
    static let phoneItem = NSPasteboard.PasteboardType("com.macinroid.phone-item")
}

/// What the phone pane puts on the pasteboard for one dragged item: a file
/// promise, so that it can be dropped in Finder, plus its location on the
/// phone, which is all a drop inside the app needs.
final class PhoneItemPromise: NSFilePromiseProvider {
    struct Reference: Codable {
        var path: String
        var storageID: UInt32
    }

    var reference: Reference?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.phoneItem]
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .phoneItem ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard type == .phoneItem else { return super.pasteboardPropertyList(forType: type) }
        return reference.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
    }
}

extension DragPayload {
    /// Reads what a drag carries. Items of the phone win over files, because
    /// their promises can look like files to the pasteboard.
    init?(pasteboard: NSPasteboard) {
        let references = (pasteboard.pasteboardItems ?? []).compactMap { item -> PhoneItemPromise.Reference? in
            guard let text = item.string(forType: .phoneItem) else { return nil }
            return try? JSONDecoder().decode(PhoneItemPromise.Reference.self, from: Data(text.utf8))
        }
        if let storageID = references.first?.storageID {
            self = .phoneItems(references.map(\.path), storageID: storageID)
            return
        }

        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return nil }
        self = .macFiles(urls.map(\.path))
    }
}

/// Delivers phone items that were dropped outside the app, in Finder for instance.
///
/// The system asks for every promised file separately. The requests of one
/// drop are gathered and fetched as a single transfer.
@MainActor
final class FilePromiseFulfiller: NSObject, NSFilePromiseProviderDelegate {
    private struct Request {
        var reference: PhoneItemPromise.Reference
        var destination: URL
        var completion: @Sendable ((any Error)?) -> Void
    }

    private weak var app: AppModel?
    private var pending: [Request] = []
    private var flushTask: Task<Void, Never>?

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(app: AppModel) {
        self.app = app
    }

    func promise(for item: FileItem, storageID: UInt32) -> PhoneItemPromise {
        let promise = PhoneItemPromise(fileType: item.contentType.identifier, delegate: self)
        promise.reference = .init(path: item.path, storageID: storageID)
        return promise
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        let path = (filePromiseProvider as? PhoneItemPromise)?.reference?.path
        return path.map(FilePath.name(of:)) ?? "Untitled"
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard let reference = (filePromiseProvider as? PhoneItemPromise)?.reference else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        Task { @MainActor in
            pending.append(Request(reference: reference, destination: url, completion: completionHandler))
            flushTask?.cancel()
            flushTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { flush() }
            }
        }
    }

    private func flush() {
        let requests = pending
        pending = []
        guard let app, let first = requests.first else { return }

        // Fetch into a scratch folder on the destination's volume, then move
        // each item to the exact name the system asked for.
        guard let scratch = try? FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: first.destination, create: true
        ) else {
            requests.forEach { $0.completion(CocoaError(.fileWriteUnknown)) }
            return
        }

        app.download(requests.map(\.reference.path), storageID: first.reference.storageID, to: scratch.path) { succeeded in
            for request in requests {
                let fetched = scratch.appendingPathComponent(FilePath.name(of: request.reference.path))
                do {
                    guard succeeded else { throw CocoaError(.fileWriteUnknown) }
                    try? FileManager.default.removeItem(at: request.destination)
                    try FileManager.default.moveItem(at: fetched, to: request.destination)
                    request.completion(nil)
                } catch {
                    request.completion(error)
                }
            }
            try? FileManager.default.removeItem(at: scratch)
        }
    }
}

// MARK: - Menus

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, symbol: String? = nil, isEnabled: Bool = true, isOn: Bool = false, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: "")
        self.handler = handler
        self.isEnabled = isEnabled
        target = self
        state = isOn ? .on : .off
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    @objc private func run() {
        handler?()
    }
}

extension AppModel {
    /// The context menu for a pane. `clicked` is the item under the pointer,
    /// which is part of the selection by the time this is called.
    func contextMenu(for pane: PaneKind, clicked: FileItem?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let browser = browser(pane)
        let selected = browser.selectedItems
        let other = title(for: pane.other)

        if clicked != nil, !selected.isEmpty {
            menu.addItem(ActionMenuItem("Open", symbol: "arrow.up.forward.app") { [self] in openSelection(in: pane) })
            if settings.showMacPane {
                menu.addItem(ActionMenuItem(
                    "Copy to \(other)",
                    symbol: pane == .mac ? "arrow.right.circle" : "arrow.left.circle",
                    isEnabled: canCopyToOtherPane(from: pane)
                ) { [self] in copySelectionToOtherPane(from: pane) })
            }
            if pane == .phone {
                menu.addItem(ActionMenuItem("Download to “\(settings.downloadFolderName)”", symbol: Symbol.downloads.rawValue) { [self] in
                    downloadSelection()
                })
                menu.addItem(ActionMenuItem("Download To…") { [self] in chooseFolderAndDownloadSelection() })
            }
            menu.addItem(.separator())

            if pane == .mac {
                menu.addItem(ActionMenuItem("Show in Finder", symbol: "finder") { [self] in showInFinder(selected) })
            }
            menu.addItem(ActionMenuItem("Quick Look", symbol: "eye", isEnabled: canQuickLook(in: pane)) { [self] in
                toggleQuickLook(in: pane)
            })
            menu.addItem(ActionMenuItem("Rename…", symbol: "pencil", isEnabled: selected.count == 1) { [self] in requestRename(in: pane) })
            menu.addItem(ActionMenuItem(pane == .mac ? "Move to Trash" : "Delete…", symbol: "trash") { [self] in deleteSelection(in: pane) })
            menu.addItem(.separator())

            menu.addItem(ActionMenuItem("Copy", symbol: "doc.on.doc") { [self] in copy(in: pane) })
            menu.addItem(ActionMenuItem("Add to Clipboard", symbol: "doc.badge.plus") { [self] in addToClipboard(in: pane) })
        }

        menu.addItem(ActionMenuItem("Paste", symbol: "doc.on.clipboard", isEnabled: canPaste(in: pane)) { [self] in paste(in: pane) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("New Folder", symbol: "folder.badge.plus") { [self] in requestNewFolder(in: pane) })

        if clicked == nil {
            if pane == .phone {
                menu.addItem(ActionMenuItem("Upload Files…", symbol: Symbol.uploads.rawValue, isEnabled: canUpload()) { [self] in
                    chooseFilesToUpload()
                })
            }
            menu.addItem(ActionMenuItem("Refresh", symbol: "arrow.clockwise") { [self] in refresh(pane) })
            if pane == .mac {
                menu.addItem(ActionMenuItem("Show in Finder", symbol: "finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: browser.path, isDirectory: true))
                })
            }
            menu.addItem(.separator())

            let hidden = settings.showsHiddenFiles(in: pane)
            menu.addItem(ActionMenuItem("Show Hidden Files", isOn: hidden) { [self] in setShowsHiddenFiles(!hidden, in: pane) })

            let sortMenu = NSMenu()
            sortMenu.autoenablesItems = false
            for key in FileSort.Key.allCases {
                sortMenu.addItem(ActionMenuItem(key.title, isOn: browser.sort.key == key) {
                    browser.sort = FileSort(key: key, ascending: browser.sort.key == key ? !browser.sort.ascending : true)
                })
            }
            let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
            sortItem.submenu = sortMenu
            menu.addItem(sortItem)
        }

        return menu
    }
}

// MARK: - Keys

/// The keys both file views treat alike. Commands with a ⌘ shortcut live in
/// the menu bar and never get here.
@MainActor
enum BrowserKeys {
    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let escape: UInt16 = 53
    }

    /// Returns whether the key was handled.
    static func handle(_ event: NSEvent, app: AppModel, pane: PaneKind) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let browser = app.browser(pane)

        switch (event.keyCode, modifiers) {
        case (KeyCode.returnKey, []), (KeyCode.enter, []):
            // as in Finder, Return renames; ⌘O and ⌘↓ open
            guard browser.selection.count == 1 else { return false }
            app.requestRename(in: pane)
        case (KeyCode.tab, []), (KeyCode.tab, .shift):
            app.switchPane()
        case (KeyCode.space, []):
            guard !browser.selection.isEmpty || app.quickLook.isVisible else { return false }
            app.toggleQuickLook(in: pane)
        case (KeyCode.delete, []), (KeyCode.forwardDelete, []):
            guard !browser.selection.isEmpty else { return false }
            app.deleteSelection(in: pane)
        case (KeyCode.escape, []):
            guard !browser.selection.isEmpty else { return false }
            browser.selection = []
        default:
            return false
        }
        return true
    }
}

/// Selects by typing the first letters of a name, for views that lack it.
@MainActor
final class TypeSelect {
    private var typed = ""
    private var lastKeyTime = Date.distantPast

    /// Returns the index of the item to select for the typed character, if the event is one.
    func index(for event: NSEvent, names: [String]) -> Int? {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).contains($0) })
        else { return nil }

        let now = Date()
        typed = now.timeIntervalSince(lastKeyTime) > 1 ? characters : typed + characters
        lastKeyTime = now

        return names.firstIndex { $0.range(of: typed, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil }
    }
}
