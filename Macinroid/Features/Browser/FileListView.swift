import AppKit
import Quartz
import SwiftUI

/// A pane's folder as a table with sortable columns, like Finder's list view.
struct FileListView: NSViewRepresentable {
    let app: AppModel
    let pane: PaneKind

    // Read here so that SwiftUI calls `updateNSView` when they change.
    let revision: Int
    let selection: Set<FileItem.ID>
    let sort: FileSort
    let isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(app: app, pane: pane)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = FileTableView()
        tableView.coordinator = context.coordinator
        context.coordinator.configure(tableView)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(revision: revision, selection: selection, sort: sort, isActive: isActive)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private enum Column: String, CaseIterable {
            case name, modified, size, kind

            var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }

            var title: String {
                switch self {
                case .name: "Name"
                case .modified: "Date Modified"
                case .size: "Size"
                case .kind: "Kind"
                }
            }

            var sortKey: FileSort.Key {
                switch self {
                case .name: .name
                case .modified: .modified
                case .size: .size
                case .kind: .kind
                }
            }

            /// (default, minimum) width
            var widths: (CGFloat, CGFloat) {
                switch self {
                case .name: (220, 110)
                case .modified: (150, 132)
                case .size: (76, 64)
                case .kind: (100, 66)
                }
            }
        }

        let app: AppModel
        let pane: PaneKind

        private weak var tableView: FileTableView?
        private var items: [FileItem] = []
        private var appliedRevision = -1
        private var isActive = false
        private var wasActive = false
        private var didSizeColumns = false
        private var isSyncing = false
        private lazy var promises = FilePromiseFulfiller(app: app)

        init(app: AppModel, pane: PaneKind) {
            self.app = app
            self.pane = pane
        }

        private var browser: BrowserModel { app.browser(pane) }

        func configure(_ tableView: FileTableView) {
            self.tableView = tableView

            for column in Column.allCases {
                let tableColumn = NSTableColumn(identifier: column.identifier)
                tableColumn.title = column.title
                tableColumn.width = column.widths.0
                tableColumn.minWidth = column.widths.1
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
                if column == .size { tableColumn.headerCell.alignment = .right }
                tableView.addTableColumn(tableColumn)
            }

            tableView.dataSource = self
            tableView.delegate = self
            tableView.style = .inset
            tableView.rowHeight = 24
            tableView.usesAlternatingRowBackgroundColors = true
            tableView.allowsMultipleSelection = true
            tableView.allowsEmptySelection = true
            tableView.allowsColumnReordering = true
            tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            tableView.autosaveName = "Files-\(pane.rawValue)"
            tableView.autosaveTableColumns = true
            tableView.target = self
            tableView.doubleAction = #selector(openClickedRow)
            tableView.registerForDraggedTypes([.fileURL, .phoneItem])
            tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
            tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
            tableView.setAccessibilityLabel(pane == .mac ? "Files on Mac" : "Files on phone")
        }

        func update(revision: Int, selection: Set<FileItem.ID>, sort: FileSort, isActive: Bool) {
            guard let tableView else { return }
            isSyncing = true
            defer { isSyncing = false }

            if revision != appliedRevision {
                appliedRevision = revision
                items = browser.items
                tableView.reloadData()
            }

            let rows = IndexSet(items.indices.filter { selection.contains(items[$0].id) })
            if rows != tableView.selectedRowIndexes {
                tableView.selectRowIndexes(rows, byExtendingSelection: false)
                if let first = rows.first, rows.count == 1 { tableView.scrollRowToVisible(first) }
            }

            let descriptor = NSSortDescriptor(key: sort.key.rawValue, ascending: sort.ascending)
            if tableView.sortDescriptors.first != descriptor {
                tableView.sortDescriptors = [descriptor]
            }

            self.isActive = isActive
            focusIfActive()
        }

        /// Gives the table the keyboard when its pane becomes the active one.
        func focusIfActive() {
            guard let tableView, let window = tableView.window else { return }

            if !didSizeColumns {
                // let the name column take up whatever room the others leave
                didSizeColumns = true
                tableView.sizeToFit()
            }

            guard isActive else {
                wasActive = false
                return
            }
            if !wasActive, window.firstResponder !== tableView, !(window.firstResponder is NSText) {
                window.makeFirstResponder(tableView)
            }
            wasActive = true
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue), items.indices.contains(row) else {
                return nil
            }
            let item = items[row]

            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? FileCellView
                ?? FileCellView(identifier: tableColumn.identifier, showsIcon: column == .name)

            cell.label.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail

            switch column {
            case .name:
                cell.label.stringValue = item.name
                cell.label.toolTip = item.name
                cell.icon?.image = FileIcons.icon(for: item, in: pane)
                cell.label.textColor = .labelColor
            case .modified:
                cell.label.stringValue = Format.date(item.modified)
                cell.label.textColor = .secondaryLabelColor
            case .size:
                cell.label.stringValue = item.isFolder || item.isPackage ? "--" : Format.bytes(item.size)
                cell.label.alignment = .right
                cell.label.textColor = .secondaryLabelColor
            case .kind:
                cell.label.stringValue = FileKind.description(for: item)
                cell.label.textColor = .secondaryLabelColor
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            items.indices.contains(row) ? items[row].name : nil
        }

        // MARK: Selection and sorting

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let tableView else { return }
            let selected = Set(tableView.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].id : nil })
            if selected != browser.selection {
                browser.selection = selected
            }
            if pane == .mac {
                app.quickLook.update(browser.selectedItems.map { URL(fileURLWithPath: $0.path) })
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isSyncing, let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key.flatMap(FileSort.Key.init(rawValue:)) else { return }
            browser.sort = FileSort(key: key, ascending: descriptor.ascending)
        }

        // MARK: Actions

        @objc private func openClickedRow() {
            guard let tableView, items.indices.contains(tableView.clickedRow) else { return }
            app.open(items[tableView.clickedRow], in: pane)
        }

        func activate() {
            app.activate(pane)
        }

        func handleKey(_ event: NSEvent) -> Bool {
            BrowserKeys.handle(event, app: app, pane: pane)
        }

        /// The menu for a right-click at `row`; -1 means the empty area.
        func menu(forRow row: Int) -> NSMenu? {
            guard app.isAvailable(pane), let tableView else { return nil }
            activate()

            let clicked = items.indices.contains(row) ? items[row] : nil
            if let clicked {
                // a right-click outside the selection moves the selection there
                if !browser.selection.contains(clicked.id) {
                    tableView.selectRowIndexes([row], byExtendingSelection: false)
                }
            } else {
                tableView.deselectAll(nil)
            }
            return app.contextMenu(for: pane, clicked: clicked)
        }

        // MARK: Drag and drop

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard items.indices.contains(row) else { return nil }
            let item = items[row]

            switch pane {
            case .mac:
                return URL(fileURLWithPath: item.path) as NSURL
            case .phone:
                guard let storage = app.session.selectedStorageID else { return nil }
                return promises.promise(for: item, storageID: storage)
            }
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: any NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard (info.draggingSource as? NSTableView) !== tableView,
                  let payload = DragPayload(pasteboard: info.draggingPasteboard),
                  app.canDrop(payload, on: pane)
            else { return [] }

            // onto a folder drops into it; anywhere else means the folder being shown
            if dropOperation != .on || !items.indices.contains(row) || !items[row].isFolder {
                tableView.setDropRow(-1, dropOperation: .on)
            }
            return .copy
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: any NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let payload = DragPayload(pasteboard: info.draggingPasteboard) else { return false }
            let folder = dropOperation == .on && items.indices.contains(row) && items[row].isFolder ? items[row].path : nil
            return app.drop(payload, on: pane, into: folder)
        }
    }
}

// MARK: - Views

final class FileTableView: NSTableView {
    weak var coordinator: FileListView.Coordinator?

    override func keyDown(with event: NSEvent) {
        if coordinator?.handleKey(event) != true {
            super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.activate() }
        return became
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // once layout has given the table its width
        DispatchQueue.main.async { [weak self] in self?.coordinator?.focusIfActive() }
    }

    override func mouseDown(with event: NSEvent) {
        coordinator?.activate()
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.menu(forRow: row(at: convert(event.locationInWindow, from: nil)))
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

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let coordinator else { return false }
        switch item.action {
        case #selector(copy(_:)): return coordinator.app.canCopy(in: coordinator.pane)
        case #selector(paste(_:)): return coordinator.app.canPaste(in: coordinator.pane)
        default: return super.validateUserInterfaceItem(item)
        }
    }

    // Quick Look takes its files from whichever view is first responder.
    // AppKit calls these on the main thread, although it does not say so.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { coordinator?.pane == .mac }
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

/// A table cell with a label and, in the name column, an icon.
final class FileCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    private(set) var icon: NSImageView?

    init(identifier: NSUserInterfaceItemIdentifier, showsIcon: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier

        label.lineBreakMode = .byTruncatingMiddle
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label

        if showsIcon {
            let icon = NSImageView()
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            imageView = icon
            self.icon = icon

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            ])
        } else {
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
        }

        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
