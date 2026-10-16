import AppKit
import UserNotifications

/// Tells the user about transfers outside of the window: progress in the Dock
/// and a notification when the app is in the background.
@MainActor
enum TransferFeedback {
    // MARK: Dock

    private static var dockView: DockProgressView?

    /// Shows progress on the Dock icon. `fraction` is 0…1; nil removes the bar.
    static func setDockProgress(_ fraction: Double?) {
        let tile = NSApp.dockTile

        guard let fraction else {
            if dockView != nil {
                dockView = nil
                tile.contentView = nil
                tile.display()
            }
            return
        }

        let view = dockView ?? DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
        // redrawing the Dock tile is costly; whole percents are fine enough
        let rounded = (fraction * 100).rounded() / 100
        guard dockView == nil || view.fraction != rounded else { return }

        view.fraction = rounded
        dockView = view
        tile.contentView = view
        tile.display()
    }

    private final class DockProgressView: NSView {
        var fraction = 0.0

        override func draw(_ dirtyRect: NSRect) {
            NSApp.applicationIconImage.draw(in: bounds)

            let track = NSRect(x: bounds.width * 0.1, y: bounds.height * 0.06, width: bounds.width * 0.8, height: bounds.height * 0.085)
            let radius = track.height / 2

            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

            var bar = track.insetBy(dx: 1.5, dy: 1.5)
            bar.size.width = max(bar.height, bar.width * min(1, max(0, fraction)))
            NSColor.white.setFill()
            NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        }
    }

    // MARK: Notifications

    /// Called when a transfer is over.
    static func jobEnded(_ job: TransferJob, notify: Bool) {
        guard notify, !NSApp.isActive else { return }

        let content = UNMutableNotificationContent()
        switch job.phase {
        case .finished:
            content.title = job.title
            content.body = "\(Format.items(job.progress.filesDone)) · \(Format.bytes(job.progress.bytesDone))"
        case .failed(let error):
            content.title = job.title
            content.body = error.title
        default:
            return
        }

        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "transfer-\(job.id)", content: content, trigger: nil))
        }
    }
}
