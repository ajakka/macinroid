import AppKit

/// Gathers what is needed to look into a problem: versions, the device, a
/// protocol trace of connecting to it, and the app's recent log.
@MainActor
enum ProblemReport {
    /// Builds the report. The phone's session is closed while the trace runs
    /// and reopened afterwards.
    static func create(app: AppModel) async -> String {
        let device = app.session.device
        let storages = app.session.storages

        // the tracing tool opens the phone itself, so the app has to let go of it
        await app.session.disconnect()
        let trace = await app.session.backend.debugReport()
        await app.session.connect()

        var lines: [String] = []
        lines.append("\(AppInfo.name) \(AppInfo.version) (\(AppInfo.build))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(architecture)")
        lines.append("Created \(Date().formatted(.iso8601))")
        lines.append("")

        lines.append("== Device ==")
        if let device {
            lines.append("Name: \(device.displayName)")
            lines.append("Manufacturer: \(device.manufacturer)")
            lines.append("Software version: \(device.mtp.deviceVersion)")
            lines.append(String(format: "USB ID: %04X:%04X", device.usb.vendorId, device.usb.productId))
            lines.append("MTP: version \(device.mtp.mtpVersion), extensions \(device.mtp.mtpExtension)")
            for storage in storages {
                lines.append("Storage: \(storage.displayName), \(Format.bytes(storage.freeSpace)) free of \(Format.bytes(storage.capacity))")
            }
        } else {
            lines.append("No device was connected when the report was created.")
        }
        lines.append("")

        lines.append("== Settings ==")
        lines.append("Connect automatically: \(app.settings.connectAutomatically)")
        lines.append("Count files first: to phone \(app.settings.showOverallProgressToPhone), to Mac \(app.settings.showOverallProgressToMac)")
        lines.append("")

        lines.append("== Connection trace ==")
        lines.append(trace.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")

        lines.append("== Recent log ==")
        lines.append(Log.recentEntries().trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")

        // serial numbers and the home folder do not belong in something that gets passed on
        var report = lines.joined(separator: "\n")
        for secret in [device?.mtp.serialNumber, device?.usb.serialNumber].compactMap({ $0 }) where secret.count > 3 {
            report = report.replacingOccurrences(of: secret, with: "<serial>")
        }
        return report.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Asks where to save the report and reveals the saved file in Finder.
    /// Returns the file, or nil if the user changed their mind.
    static func save(_ report: String, in window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Problem Report"
        panel.nameFieldStringValue = "Macinroid Report \(Date().formatted(.iso8601.year().month().day())).txt"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        let response = if let window { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        guard response == .OK, let url = panel.url else { return nil }

        do {
            try Data(report.utf8).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return url
        } catch {
            Log.error("saving the problem report failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static var architecture: String {
        #if arch(arm64)
        "Apple silicon"
        #else
        "Intel"
        #endif
    }
}
