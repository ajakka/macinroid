import SwiftUI
import XCTest
@testable import Macinroid

/// Lays out the windows and sheets that are not part of the main window, to
/// catch views that crash or collapse.
///
/// Set `MACINROID_SNAPSHOT_DIR` (as `TEST_RUNNER_MACINROID_SNAPSHOT_DIR` for
/// xcodebuild) to also save a picture of each of them there.
@MainActor
final class AuxiliaryViewTests: XCTestCase {
    func testAuxiliaryViewsLayOut() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MacinroidViews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let settings = AppSettings(defaults: UserDefaults(suiteName: "MacinroidViews-\(UUID().uuidString)")!)
        let backend = SimulatedBackend(configuration: .init(root: scratch, bytesPerSecond: nil, seedSampleContent: false))
        let app = AppModel(settings: settings, backend: backend)
        let connected = await app.session.connect()
        XCTAssertTrue(connected)

        let updates = UpdateChecker(settings: settings, repository: "example/macinroid")
        let item = FileItem(path: "/Holiday photos.zip", name: "Holiday photos.zip", isFolder: false, size: 1024)

        let views: [(name: String, view: AnyView)] = [
            ("settings", AnyView(SettingsView())),
            ("welcome", AnyView(WelcomeView())),
            ("help", AnyView(HelpView().frame(width: 620, height: 680))),
            ("shortcuts", AnyView(KeyboardShortcutsView())),
            ("report", AnyView(ReportProblemView())),
            ("update", AnyView(UpdateView())),
            ("new-folder", AnyView(NameSheet(pane: .phone, purpose: .newFolder))),
            ("rename", AnyView(NameSheet(pane: .phone, purpose: .rename(item)))),
            ("go-to-folder", AnyView(GoToFolderSheet(pane: .mac))),
            ("device-info", AnyView(DeviceInfoSheet())),
            ("transfers", AnyView(TransfersPopover())),
        ]

        for (name, view) in views {
            let host = NSHostingView(rootView: view.environment(app).environment(updates))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            let size = host.fittingSize
            XCTAssertGreaterThan(size.width, 200, name)
            XCTAssertGreaterThan(size.height, 100, name)

            if let directory = ProcessInfo.processInfo.environment["MACINROID_SNAPSHOT_DIR"] {
                window.setContentSize(size)
                host.layoutSubtreeIfNeeded()
                // give text fields and async content a moment to settle
                try await Task.sleep(for: .milliseconds(150))

                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            }
            window.close()
        }
    }
}
