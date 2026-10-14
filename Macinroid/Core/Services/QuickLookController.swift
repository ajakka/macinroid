import AppKit
import Quartz

/// One file in the Quick Look panel.
///
/// A file on the phone has no URL until a copy of it is on the Mac; until
/// then the panel shows its name and a spinner.
final class PreviewItem: NSObject, QLPreviewItem {
    /// The file's path, on the Mac or on the phone.
    let id: String
    /// The file on the phone, with the storage it is on.
    let phoneFile: (item: FileItem, storage: UInt32)?

    var previewItemURL: URL?
    var previewItemTitle: String?

    init(macFile path: String) {
        id = path
        phoneFile = nil
        previewItemURL = URL(fileURLWithPath: path)
    }

    init(phoneFile item: FileItem, storage: UInt32, localCopy: URL?) {
        id = item.path
        phoneFile = (item, storage)
        previewItemURL = localCopy
        previewItemTitle = item.name
    }
}

/// Drives the Quick Look panel.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private(set) var items: [PreviewItem] = []

    /// Called when the panel shows an item, which is when a phone file's copy is wanted.
    var onShowItem: ((PreviewItem) -> Void)?
    /// Called when the panel has closed.
    var onClose: (() -> Void)?

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// Whether the panel shows files from the phone.
    var isShowingPhoneFiles: Bool {
        isVisible && items.contains { $0.phoneFile != nil }
    }

    /// Opens the panel for the items, or closes it when it is open.
    func toggle(_ items: [PreviewItem]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else if !items.isEmpty {
            self.items = items
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    /// Follows the selection while the panel is open.
    func update(_ items: [PreviewItem]) {
        guard isVisible, items.map(\.id) != self.items.map(\.id), !items.isEmpty else { return }
        self.items = items
        QLPreviewPanel.shared().reloadData()
    }

    /// Shows the file of an item whose copy has just arrived.
    func itemDidLoad(_ item: PreviewItem) {
        guard isVisible, let panel = QLPreviewPanel.shared(), items.indices.contains(panel.currentPreviewItemIndex),
              items[panel.currentPreviewItemIndex] === item
        else { return }
        panel.refreshCurrentPreviewItem()
    }

    /// The item the panel is showing.
    var currentItem: PreviewItem? {
        guard isVisible, let panel = QLPreviewPanel.shared(), items.indices.contains(panel.currentPreviewItemIndex) else { return nil }
        return items[panel.currentPreviewItemIndex]
    }

    func close() {
        guard isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    // The panel adopts whichever view is first responder and implements these.
    func takeControl(of panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func releaseControl(of panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
        onClose?()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        onShowItem?(item)
        return item
    }
}
