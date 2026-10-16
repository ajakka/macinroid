import SwiftUI

enum WindowID {
    static let main = "main"
    static let welcome = "welcome"
    static let help = "help"
    static let shortcuts = "shortcuts"
    static let report = "report"
    static let update = "update"
}

/// How this launch of the app was set up.
@MainActor
enum AppEnvironment {
    /// The app is only running to host its unit tests.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Launched with `-SimulatedDevice YES`: use a pretend phone instead of USB.
    static let usesSimulatedDevice = UserDefaults.standard.bool(forKey: "SimulatedDevice")

    /// Set once the app's model exists; the app delegate reads it.
    static var app: AppModel?

    static func makeBackend() -> any DeviceBackend {
        guard usesSimulatedDevice || isRunningTests else { return MTPBackend() }

        let root = UserDefaults.standard.string(forKey: "SimulatedDeviceRoot").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Macinroid/SimulatedDevice", isDirectory: true)
        return SimulatedBackend(configuration: .init(root: root))
    }
}

@main
struct MacinroidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    @State private var app: AppModel
    @State private var updates: UpdateChecker

    init() {
        let model = AppModel(settings: AppSettings(), backend: AppEnvironment.makeBackend())
        AppEnvironment.app = model
        _app = State(initialValue: model)
        _updates = State(initialValue: UpdateChecker(settings: model.settings))
    }

    var body: some Scene {
        Window(AppInfo.name, id: WindowID.main) {
            MainView()
                .environment(app)
                .environment(updates)
                .frame(minWidth: app.settings.showMacPane ? 860 : 620, minHeight: 460)
        }
        .defaultSize(width: 1080, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(app: app, updates: updates)
        }

        Settings {
            SettingsView()
                .environment(app)
                .environment(updates)
        }

        Window("Welcome to \(AppInfo.name)", id: WindowID.welcome) {
            WelcomeView()
                .environment(app)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("\(AppInfo.name) Help", id: WindowID.help) {
            HelpView()
                .environment(app)
        }
        .defaultSize(width: 620, height: 680)

        Window("Keyboard Shortcuts", id: WindowID.shortcuts) {
            KeyboardShortcutsView()
        }
        .windowResizability(.contentSize)

        Window("Report a Problem", id: WindowID.report) {
            ReportProblemView()
                .environment(app)
        }
        .windowResizability(.contentSize)

        Window("Software Update", id: WindowID.update) {
            UpdateView()
                .environment(updates)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isShuttingDown = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // closing the window must not cut a transfer short
        !(AppEnvironment.app?.transfers.hasWork ?? false) && !AppEnvironment.isRunningTests
    }

    /// Files dropped on the Dock icon, or opened with the app, are copied to the phone.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppEnvironment.app?.upload(filesFromOutside: urls.filter(\.isFileURL).map(\.path))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app = AppEnvironment.app, !AppEnvironment.isRunningTests, !isShuttingDown else { return .terminateNow }

        Task {
            if app.transfers.hasWork {
                let quit = await app.confirm(
                    title: "A transfer is in progress.",
                    message: "If you quit now, the items that haven’t been copied yet won’t be.",
                    action: "Quit"
                )
                guard quit else {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                app.isQuitting = true
                app.transfers.cancelAll()
                await app.transfers.waitUntilIdle()
            }

            // release the phone, so that other apps can talk to it afterwards
            isShuttingDown = true
            await app.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
