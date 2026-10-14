import SwiftUI

/// The menu bar.
struct AppCommands: Commands {
    let app: AppModel
    let updates: UpdateChecker

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let pane = app.activePane
        let browser = app.activeBrowser
        let canAct = app.isAvailable(pane) && browser.error == nil
        let hasSelection = canAct && !browser.selection.isEmpty

        CommandGroup(replacing: .appInfo) {
            Button("About \(AppInfo.name)") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .credits: NSAttributedString(
                        string: "A native Mac app for moving files to and from Android phones.\n\nInspired by OpenMTP by Ganesh Rathinavel.",
                        attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
                    ),
                ])
                NSApp.activate()
            }
            Button("Check for Updates…") {
                openWindow(id: WindowID.update)
                Task { await updates.check(userInitiated: true) }
            }
            .disabled(!updates.isAvailable)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Folder") { run { app.requestNewFolder(in: pane) } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!canAct)

            Divider()

            Button("Open") { run { app.openSelection(in: pane) } }
                .keyboardShortcut("o")
                .disabled(!hasSelection)
            Button("Quick Look") {
                run { app.quickLook.toggle(browser.selectedItems.map { URL(fileURLWithPath: $0.path) }) }
            }
            .keyboardShortcut("y")
            .disabled(!hasSelection || pane != .mac)
            Button("Show in Finder") { run { app.showInFinder(browser.selectedItems) } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!hasSelection || pane != .mac)

            Divider()

            if app.settings.showMacPane {
                Button("Copy to \(app.title(for: pane.other))") { run { app.copySelectionToOtherPane(from: pane) } }
                    .keyboardShortcut("t")
                    .disabled(!app.canCopyToOtherPane(from: pane))
            }
            Button("Download to “\(app.settings.downloadFolderName)”") { run { app.downloadSelection() } }
                .keyboardShortcut("d")
                .disabled(!app.canDownloadSelection())
            Button("Download To…") { run { app.chooseFolderAndDownloadSelection() } }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(!app.canDownloadSelection())
            Button("Upload Files…") { run { app.chooseFilesToUpload() } }
                .keyboardShortcut("u")
                .disabled(!app.canUpload())

            Divider()

            Button("Rename…") { run { app.requestRename(in: pane) } }
                .disabled(!canAct || browser.selection.count != 1)
            Button(pane == .mac ? "Move to Trash" : "Delete…") { run { app.deleteSelection(in: pane) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!hasSelection)
        }

        CommandGroup(after: .pasteboard) {
            Button("Add to Clipboard") { run { app.addToClipboard(in: pane) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!hasSelection)
        }

        CommandGroup(before: .sidebar) {
            Picker("View", selection: Binding(get: { browser.viewMode }, set: { browser.viewMode = $0 })) {
                Text("as Icons").tag(ViewMode.grid).keyboardShortcut("1")
                Text("as List").tag(ViewMode.list).keyboardShortcut("2")
            }
            .pickerStyle(.inline)

            Picker("Sort By", selection: Binding(
                get: { browser.sort.key },
                set: { browser.sort = FileSort(key: $0, ascending: true) }
            )) {
                ForEach(FileSort.Key.allCases) { key in
                    Text(key.title).tag(key)
                }
            }
            Toggle("Sort Descending", isOn: Binding(
                get: { !browser.sort.ascending },
                set: { browser.sort = FileSort(key: browser.sort.key, ascending: !$0) }
            ))

            Divider()

            Toggle("Show Hidden Files", isOn: Binding(
                get: { app.settings.showsHiddenFiles(in: pane) },
                set: { app.setShowsHiddenFiles($0, in: pane) }
            ))
            .keyboardShortcut(".", modifiers: [.command, .shift])
            Toggle("Show Status Bar", isOn: Binding(
                get: { app.settings.showStatusBar },
                set: { app.settings.showStatusBar = $0 }
            ))
            .keyboardShortcut("/")
            Toggle("Show Mac Pane", isOn: Binding(
                get: { app.settings.showMacPane },
                set: { app.settings.showMacPane = $0 }
            ))

            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { run { app.goBack(pane) } }
                .keyboardShortcut("[")
                .disabled(!browser.canGoBack)
            Button("Forward") { run { app.goForward(pane) } }
                .keyboardShortcut("]")
                .disabled(!browser.canGoForward)
            Button("Enclosing Folder") { run { app.goUp(pane) } }
                .keyboardShortcut(.upArrow)
                .disabled(!app.isAvailable(pane) || !browser.canGoUp)
            Button("Open Selection") { run { app.openSelection(in: pane) } }
                .keyboardShortcut(.downArrow)
                .disabled(!hasSelection)

            Divider()

            Button("Switch Pane") { run { app.switchPane() } }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(!app.settings.showMacPane)
            Button("Refresh") { run { app.refresh(pane) } }
                .keyboardShortcut("r")

            Divider()

            Group {
                Button("Home") { go(to: LocalFileSystem.homePath) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Desktop") { go(to: LocalFileSystem.homePath + "/Desktop") }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Documents") { go(to: LocalFileSystem.homePath + "/Documents") }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Downloads") { go(to: LocalFileSystem.homePath + "/Downloads") }
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }
            .disabled(!app.settings.showMacPane)

            Divider()

            Button("Go to Folder…") { run { app.requestGoToFolder(in: pane) } }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!app.isAvailable(pane))
        }

        CommandMenu("Device") {
            let session = app.session

            if session.storages.count > 0 {
                Picker("Storage", selection: Binding(
                    get: { session.selectedStorageID ?? 0 },
                    set: { app.selectStorage($0) }
                )) {
                    ForEach(session.storages) { storage in
                        Text(storage.displayName).tag(storage.id)
                    }
                }
                .pickerStyle(.inline)
                .disabled(app.transfers.isBusy)

                Divider()
            }

            Button("Device Info…") { app.sheet = .deviceInfo }
                .keyboardShortcut("i")
                .disabled(!session.isConnected)
            Button(session.isConnected ? "Refresh Device" : "Connect") { app.refresh(.phone) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Disconnect") { Task { await session.disconnect() } }
                .keyboardShortcut("e")
                .disabled(!session.isConnected || app.transfers.isBusy)

            Divider()

            Button("Cancel Transfer") { app.transfers.cancelAll() }
                .keyboardShortcut(".")
                .disabled(!app.transfers.hasWork)
        }

        CommandGroup(replacing: .help) {
            Button("\(AppInfo.name) Help") { openWindow(id: WindowID.help) }
                .keyboardShortcut("?")
            Button("Keyboard Shortcuts") { openWindow(id: WindowID.shortcuts) }
            Button("Welcome to \(AppInfo.name)") { openWindow(id: WindowID.welcome) }

            Divider()

            Button("Report a Problem…") { openWindow(id: WindowID.report) }
            Button("OpenMTP on GitHub") { NSWorkspace.shared.open(AppInfo.openMTPURL) }
        }
    }

    /// Runs a command that acts on the file panes, but only while the main
    /// window has the focus and nothing in it is being typed into: ⌘⌫ in a
    /// text field must never delete files.
    private func run(_ command: () -> Void) {
        guard let window = app.window, window.isKeyWindow, window.attachedSheet == nil,
              !(window.firstResponder is NSText)
        else {
            NSSound.beep()
            return
        }
        command()
    }

    private func go(to path: String) {
        run { app.navigate(.mac, to: path) }
    }
}
