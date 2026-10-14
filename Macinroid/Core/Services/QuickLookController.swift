import AppKit
import Quartz

/// Drives the Quick Look panel for files on the Mac.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var urls: [URL] = []

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// Opens the panel for the files, or closes it when it is open.
    func toggle(_ urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else if !urls.isEmpty {
            self.urls = urls
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    /// Follows the selection while the panel is open.
    func update(_ urls: [URL]) {
        guard isVisible, urls != self.urls, !urls.isEmpty else { return }
        self.urls = urls
        QLPreviewPanel.shared().reloadData()
    }

    // The panel adopts whichever view is first responder and implements these.
    func takeControl(of panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func releaseControl(of panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}
