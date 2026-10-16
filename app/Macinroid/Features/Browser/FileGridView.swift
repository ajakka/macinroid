import AppKit
import Quartz
import SwiftUI

/// A pane's folder as a grid of icons, like Finder's icon view.
struct FileGridView: NSViewRepresentable {
    let app: AppModel
    let pane: PaneKind

    // Read here so that SwiftUI calls `updateNSView` when they change.
    let revision: Int
    let selection: Set<FileItem.ID>
    let isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(app: app, pane: pane)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let collectionView = FileCollectionView()
        collectionView.coordinator = context.coordinator
        context.coordinator.configure(collectionView)

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(revision: revision, selection: selection, isActive: isActive)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let app: AppModel
        let pane: PaneKind

        private weak var collectionView: FileCollectionView?
        private var items: [FileItem] = []
        private var appliedRevision = -1
        private var isActive = false
        private var wasActive = false
        private var isSyncing = false
        private let typeSelect = TypeSelect()
        private lazy var promises = FilePromiseFulfiller(app: app)

        init(app: AppModel, pane: PaneKind) {
            self.app = app
            self.pane = pane
        }

        private var browser: BrowserModel { app.browser(pane) }

        func configure(_ collectionView: FileCollectionView) {
            self.collectionView = collectionView

            let layout = NSCollectionViewFlowLayout()
            layout.itemSize = FileGridItem.size
            layout.minimumInteritemSpacing = 4
            layout.minimumLineSpacing = 6
            layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            collectionView.collectionViewLayout = layout

            collectionView.dataSource = self
            collectionView.delegate = self
            collectionView.isSelectable = true
            collectionView.allowsMultipleSelection = true
            collectionView.allowsEmptySelection = true
            collectionView.backgroundColors = [.clear]
            collectionView.register(FileGridItem.self, forItemWithIdentifier: FileGridItem.identifier)
            collectionView.registerForDraggedTypes([.fileURL, .phoneItem])
            collectionView.setDraggingSourceOperationMask(.copy, forLocal: true)
            collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
            collectionView.setAccessibilityLabel(pane == .mac ? "Files on Mac" : "Files on phone")
        }

        func update(revision: Int, selection: Set<FileItem.ID>, isActive: Bool) {
            guard let collectionView else { return }
            isSyncing = true
            defer { isSyncing = false }

            if revision != appliedRevision {
                appliedRevision = revision
                items = browser.items
                collectionView.reloadData()
            }

            let indexPaths = Set(items.indices.filter { selection.contains(items[$0].id) }.map { IndexPath(item: $0, section: 0) })
            if indexPaths != collectionView.selectionIndexPaths {
                collectionView.selectionIndexPaths = indexPaths
                if indexPaths.count == 1 {
                    collectionView.scrollToItems(at: indexPaths, scrollPosition: .nearestHorizontalEdge)
                }
            }

            self.isActive = isActive
            focusIfActive()
        }

        /// Gives the grid the keyboard when its pane becomes the active one.
        func focusIfActive() {
            guard let collectionView, let window = collectionView.window else { return }
            guard isActive else {
                wasActive = false
                return
            }
            if !wasActive, window.firstResponder !== collectionView, !(window.firstResponder is NSText) {
                window.makeFirstResponder(collectionView)
            }
            wasActive = true
        }

        // MARK: Data

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let view = collectionView.makeItem(withIdentifier: FileGridItem.identifier, for: indexPath)
            if let view = view as? FileGridItem, items.indices.contains(indexPath.item) {
                view.show(items[indexPath.item], in: pane, app: app)
            }
            return view
        }

        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            (item as? FileGridItem)?.stopPreview()
        }

        // MARK: Selection

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            selectionDidChange()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            selectionDidChange()
        }

        func selectionDidChange() {
            guard !isSyncing, let collectionView else { return }
            let selected = Set(collectionView.selectionIndexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item].id : nil })
            if selected != browser.selection {
                browser.selection = selected
            }
            app.selectionDidChange(in: pane)
        }

        // MARK: Actions

        func activate() {
            app.activate(pane)
        }

        func open(at indexPath: IndexPath) {
            guard items.indices.contains(indexPath.item) else { return }
            app.open(items[indexPath.item], in: pane)
        }

        func handleKey(_ event: NSEvent) -> Bool {
            if BrowserKeys.handle(event, app: app, pane: pane) { return true }

            // typing the start of a name selects it
            if let index = typeSelect.index(for: event, names: items.map(\.name)), let collectionView {
                let indexPath: Set = [IndexPath(item: index, section: 0)]
                collectionView.selectionIndexPaths = indexPath
                collectionView.scrollToItems(at: indexPath, scrollPosition: .nearestHorizontalEdge)
                selectionDidChange()
                return true
            }
            return false
        }

        func menu(at indexPath: IndexPath?) -> NSMenu? {
            guard app.isAvailable(pane), let collectionView else { return nil }
            activate()

            let clicked = indexPath.flatMap { items.indices.contains($0.item) ? items[$0.item] : nil }
            if let clicked, let indexPath {
                if !browser.selection.contains(clicked.id) {
                    collectionView.selectionIndexPaths = [indexPath]
                    selectionDidChange()
                }
            } else {
                collectionView.deselectAll(nil)
                selectionDidChange()
            }
            return app.contextMenu(for: pane, clicked: clicked)
        }

        // MARK: Drag and drop

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
            guard items.indices.contains(indexPath.item) else { return nil }
            let item = items[indexPath.item]

            switch pane {
            case .mac:
                return URL(fileURLWithPath: item.path) as NSURL
            case .phone:
                guard let storage = app.session.selectedStorageID else { return nil }
                return promises.promise(for: item, storageID: storage)
            }
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            validateDrop draggingInfo: any NSDraggingInfo,
            proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
        ) -> NSDragOperation {
            guard (draggingInfo.draggingSource as? NSCollectionView) !== collectionView,
                  let payload = DragPayload(pasteboard: draggingInfo.draggingPasteboard),
                  app.canDrop(payload, on: pane)
            else { return [] }

            // onto a folder drops into it; anywhere else means the folder being shown
            let index = proposedDropIndexPath.pointee.item
            let isOntoFolder = proposedDropOperation.pointee == .on && items.indices.contains(index) && items[index].isFolder
            if !isOntoFolder {
                proposedDropIndexPath.pointee = NSIndexPath(forItem: items.count, inSection: 0)
                proposedDropOperation.pointee = .before
            }
            return .copy
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            acceptDrop draggingInfo: any NSDraggingInfo,
            indexPath: IndexPath,
            dropOperation: NSCollectionView.DropOperation
        ) -> Bool {
            guard let payload = DragPayload(pasteboard: draggingInfo.draggingPasteboard) else { return false }
            let isOntoFolder = dropOperation == .on && items.indices.contains(indexPath.item) && items[indexPath.item].isFolder
            return app.drop(payload, on: pane, into: isOntoFolder ? items[indexPath.item].path : nil)
        }
    }
}

// MARK: - Views

final class FileCollectionView: NSCollectionView {
    weak var coordinator: FileGridView.Coordinator?

    override func keyDown(with event: NSEvent) {
        if coordinator?.handleKey(event) != true {
            super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            coordinator?.activate()
            refreshSelectionEmphasis()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { refreshSelectionEmphasis() }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.coordinator?.focusIfActive() }
    }

    override func mouseDown(with event: NSEvent) {
        coordinator?.activate()
        super.mouseDown(with: event)

        if event.clickCount == 2, let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            coordinator?.open(at: indexPath)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.menu(at: indexPathForItem(at: convert(event.locationInWindow, from: nil)))
    }

    private func refreshSelectionEmphasis() {
        for item in visibleItems() {
            item.view.needsDisplay = true
        }
    }

    // Edit ▸ Copy and Paste reach the pane that has the focus through the responder chain.
    @objc func copy(_ sender: Any?) {
        guard let coordinator else { return }
        coordinator.app.copy(in: coordinator.pane)
    }

    @objc func paste(_ sender: Any?) {
        guard let coordinator else { return }
        coordinator.app.paste(in: coordinator.pane)
    }

    // Quick Look takes its files from whichever view is first responder.
    // AppKit calls these on the main thread, although it does not say so.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            if let panel { coordinator?.app.quickLook.takeControl(of: panel) }
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            if let panel { coordinator?.app.quickLook.releaseControl(of: panel) }
        }
    }
}

extension FileCollectionView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let coordinator else { return false }
        switch menuItem.action {
        case #selector(copy(_:)): return coordinator.app.canCopy(in: coordinator.pane)
        case #selector(paste(_:)): return coordinator.app.canPaste(in: coordinator.pane)
        default: return true
        }
    }
}

/// One file in the grid: its icon above its name.
final class FileGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileGridItem")
    static let size = NSSize(width: 108, height: 112)
    private static let iconSize: CGFloat = 64

    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var shownPath: String?
    private var preview: PhoneThumbnails.Ticket?

    override func loadView() {
        let background = SelectionBackgroundView()
        view = background

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        // lets a drag begin on the icon instead of the image view swallowing the click
        icon.unregisterDraggedTypes()

        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        background.addSubview(icon)
        background.addSubview(label)
        imageView = icon
        textField = label

        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: background.topAnchor, constant: 8),
            icon.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -4),
            label.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -4),
        ])
    }

    override var isSelected: Bool {
        didSet {
            (view as? SelectionBackgroundView)?.isSelected = isSelected
        }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet {
            (view as? SelectionBackgroundView)?.isDropTarget = highlightState == .asDropTarget
        }
    }

    func show(_ item: FileItem, in pane: PaneKind, app: AppModel) {
        stopPreview()
        shownPath = item.path
        label.stringValue = item.name
        label.toolTip = item.name
        icon.image = FileIcons.icon(for: item, in: pane)

        let scale = view.window?.backingScaleFactor ?? 2
        preview = app.requestIconPreview(for: item, in: pane, size: Self.iconSize, scale: scale) { [weak self] image in
            // the cell may have been reused for another file in the meantime
            if self?.shownPath == item.path { self?.icon.image = image }
        }
    }

    /// Gives up on the picture asked for, as when the item scrolls out of view.
    func stopPreview() {
        preview?.cancel()
        preview = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopPreview()
        shownPath = nil
        icon.image = nil
    }
}

/// Draws the rounded highlight behind a selected grid item.
private final class SelectionBackgroundView: NSView {
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || isDropTarget else { return }

        // full strength only while the grid has the keyboard, as lists do
        let isEmphasized = window?.isKeyWindow == true && window?.firstResponder is FileCollectionView
            && (window?.firstResponder as? NSView)?.isDescendant(of: enclosingScrollView ?? self) == true
        let color: NSColor = isDropTarget || isEmphasized
            ? .selectedContentBackgroundColor.withAlphaComponent(isDropTarget ? 0.35 : 0.25)
            : .unemphasizedSelectedContentBackgroundColor

        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
}
