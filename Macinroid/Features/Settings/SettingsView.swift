import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", symbol: .gear) }
            BrowserSettings()
                .tabItem { Label("File Browser", symbol: .folder) }
            TransferSettings()
                .tabItem { Label("Transfers", symbol: .transfers) }
        }
        .frame(width: 500)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(UpdateChecker.self) private var updates

    var body: some View {
        @Bindable var settings = app.settings

        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section {
                Toggle("Connect when a phone is plugged in", isOn: $settings.connectAutomatically)
            } footer: {
                Text("Macinroid notices when a phone is plugged in or unplugged. Turn this off if your phone keeps disconnecting; you can then connect with the Refresh button.")
            }

            Section {
                Toggle("Check for updates automatically", isOn: $settings.checkForUpdatesAutomatically)
                Toggle("Include beta versions", isOn: $settings.includeBetaUpdates)
            } footer: {
                Text(updates.isAvailable
                    ? "Beta versions give early access to new features, but may be less stable."
                    : "This copy of Macinroid has no update source configured.")
            }
            .disabled(!updates.isAvailable)
        }
        .formStyle(.grouped)
    }
}

private struct BrowserSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings

        Form {
            Section("Show hidden files") {
                Toggle("On the Mac", isOn: Binding(
                    get: { settings.showHiddenFilesOnMac },
                    set: { app.setShowsHiddenFiles($0, in: .mac) }
                ))
                Toggle("On the phone", isOn: Binding(
                    get: { settings.showHiddenFilesOnPhone },
                    set: { app.setShowsHiddenFiles($0, in: .phone) }
                ))
            }

            Section("View") {
                Picker("Mac", selection: $settings.macViewMode) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Phone", selection: $settings.phoneViewMode) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Keep folders on top", isOn: $settings.foldersFirst)
                Toggle("Show status bar", isOn: $settings.showStatusBar)
            }

            Section {
                Toggle("Show the Mac pane", isOn: $settings.showMacPane)
                Picker("Mac pane position", selection: $settings.macPaneOnLeft) {
                    Text("Left").tag(true)
                    Text("Right").tag(false)
                }
                .disabled(!settings.showMacPane)
            } header: {
                Text("Layout")
            } footer: {
                Text("Without the Mac pane, the window shows only the phone: drag files between it and Finder, or copy and paste them. With it, your Mac’s files appear next to the phone’s.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct TransferSettings: View {
    @Environment(AppModel.self) private var app

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: app.settings.downloadFolder, isDirectory: true)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            app.settings.downloadFolder = url.path
        }
    }

    var body: some View {
        @Bindable var settings = app.settings

        Form {
            Section {
                Toggle("When copying to the phone", isOn: $settings.showOverallProgressToPhone)
                Toggle("When copying to the Mac", isOn: $settings.showOverallProgressToMac)
            } header: {
                Text("Show overall progress")
            } footer: {
                Text("To show how much is left, the items are counted before the copy starts. For folders with many files this can take from a few seconds to a few minutes.")
            }

            Section {
                LabeledContent("Download to") {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: settings.downloadFolder))
                            .resizable()
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        Text(settings.downloadFolderName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseDownloadFolder() }
                    }
                }
            } footer: {
                Text("Where the Download button saves items from the phone. Dragging to Finder puts them wherever you drop them.")
            }

            Section {
                Toggle("Notify when a transfer finishes in the background", isOn: $settings.notifyWhenTransfersFinish)
            }
        }
        .formStyle(.grouped)
    }
}
