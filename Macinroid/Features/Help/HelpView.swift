import SwiftUI

/// How to connect a phone, and what to do when it will not connect.
struct HelpView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                ForEach(Array(HelpContent.connecting.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.tint)
                            .frame(width: 22, height: 22)
                            .background(.tint.opacity(0.14), in: .circle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.text)
                            if let detail = step.detail {
                                Text(detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Connecting your phone")
            }

            Section {
                ForEach(HelpContent.topics) { topic in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(topic.steps.enumerated()), id: \.offset) { _, step in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("•")
                                        .foregroundStyle(.tertiary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(step.text)
                                        if let detail = step.detail {
                                            Text(detail)
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let link = step.link {
                                            Link(link.title, destination: link.url)
                                                .font(.callout)
                                        }
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            if topic.offersPrivacySettings {
                                Button("Open Privacy Settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                            if topic.offersReport {
                                Button("Report a Problem…") { openWindow(id: WindowID.report) }
                            }
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text(topic.title)
                            .fontWeight(.medium)
                    }
                }
            } header: {
                Text("If something isn’t working")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 420)
    }
}

/// The text of the help window.
@MainActor
enum HelpContent {
    struct Step {
        var text: LocalizedStringKey
        var detail: LocalizedStringKey?
        var link: (title: String, url: URL)?

        init(_ text: LocalizedStringKey, detail: LocalizedStringKey? = nil, link: (title: String, url: URL)? = nil) {
            self.text = text
            self.detail = detail
            self.link = link
        }
    }

    struct Topic: Identifiable {
        var title: String
        var steps: [Step]
        var offersPrivacySettings = false
        var offersReport = false
        var id: String { title }
    }

    private static let smartSwitchGuide = URL(string: "https://farazfazli.medium.com/how-i-reverse-engineered-keis-and-sidesync-and-fixed-mtp-8949acbb1c29")!

    static let connecting: [Step] = [
        Step("Unlock your Android phone."),
        Step("Connect it to your Mac with a USB cable.", detail: "Use a cable that carries data; some cables only charge."),
        Step("On the phone, tap the **Charging this device via USB** notification."),
        Step("Under **Use USB for**, choose **File Transfer**."),
        Step("Macinroid connects by itself.", detail: "If it doesn’t, click Connect in the phone’s pane or press ⌘R."),
    ]

    /// Steps that put the phone's USB mode back in order.
    private static let resetUSBMode: [Step] = [
        Step("Unlock your phone, unplug it and plug it back in."),
        Step("Tap the USB notification and choose **Charging** (or **No data transfer**)."),
        Step("Tap the notification again and choose **File Transfer**."),
        Step("If the phone asks **Allow access to phone data?**, tap **Allow**."),
    ]

    static let topics: [Topic] = [
        Topic(title: "My phone isn’t connecting", steps: [
            Step("Quit apps that read USB devices: Android File Transfer, Google Drive, Dropbox, OneDrive, Preview, Image Capture and Photos.",
                 detail: "These apps can take hold of the phone before Macinroid does. Quit them completely, from the menu bar if they live there.",
                 link: ("More about apps that interfere", AppInfo.connectionHelpURL)),
            Step("Uninstall Google’s Android File Transfer if it opens every time you plug in your phone."),
            Step("Follow the steps under “Connecting your phone” again, starting with unplugging the cable."),
            Step("If the phone keeps dropping the connection, turn off **Connect when a phone is plugged in** in Settings › General, and connect with ⌘R instead."),
        ]),
        Topic(title: "Google Drive or Dropbox is installed on my Mac", steps: [
            Step("Recent versions of Google Drive and Dropbox are known to hold on to connected phones."),
            Step("Quit them from their menu bar icons, then unplug the phone and plug it back in."),
        ]),
        Topic(title: "I have a Samsung phone", steps: [
            Step("When the phone asks **Allow access to phone data?**, tap **Allow**, then click Connect."),
            Step("Uninstall Samsung Smart Switch if it is installed on your Mac; it keeps the phone to itself.",
                 link: ("How to remove Smart Switch and its drivers", smartSwitchGuide)),
            Step("Quit and reopen Macinroid, then reconnect the phone."),
        ]),
        Topic(title: "Macinroid says “Allow Access on Your Phone”", steps: [
            Step("Unlock the phone and tap **Allow** on the **Allow access to phone data?** prompt."),
            Step("If there is no prompt, unplug the phone and plug it back in."),
            Step("If you are asked again and again, see the next topic."),
        ]),
        Topic(title: "I’m asked to allow access again and again, or connecting never finishes", steps: resetUSBMode),
        Topic(title: "Macinroid says “More Than One Device Is Connected”", steps: [
            Step("Unplug every MTP device: phones, cameras, e-readers and music players."),
            Step("Plug in only the phone you want to use, then follow “Connecting your phone”."),
        ]),
        Topic(title: "My phone disconnects when its screen turns off", steps: [
            Step("On a few phones the connection ends when the display goes to sleep, which interrupts running transfers."),
            Step("On the phone, open Settings › Display › Screen timeout and choose the longest time while you copy files."),
        ]),
        Topic(title: "A transfer seems stuck", steps: [
            Step("Keep the phone unlocked while files are being copied."),
            Step("If the progress doesn’t move for a long time, cancel the transfer, reconnect the cable and try again.",
                 detail: "This is a known weakness of MTP on Android, not something a Mac app can fully prevent."),
        ]),
        Topic(title: "Macinroid can’t open a folder on my Mac", steps: [
            Step("macOS asks before an app may read your Desktop, Documents and Downloads folders, removable disks and network volumes. Click **Allow** when it asks."),
            Step("If you declined, open System Settings › Privacy & Security › Files and Folders and turn the folders on for Macinroid."),
            Step("For folders that are still off limits, add Macinroid under Privacy & Security › Full Disk Access."),
        ], offersPrivacySettings: true),
        Topic(title: "It still doesn’t work", steps: [
            Step("Try a different cable and a different USB port, without a hub in between."),
            Step("Restart the phone, then follow “Connecting your phone” again."),
            Step("Create a problem report. It contains a trace of the connection attempt that shows where it fails."),
        ], offersReport: true),
    ]
}

// MARK: - Keyboard shortcuts

struct KeyboardShortcutsView: View {
    private struct Shortcut: Identifiable {
        var title: String
        /// Alternatives, each a sequence of keys.
        var keys: [[String]]
        var id: String { title }
    }

    private static let sections: [(title: String, shortcuts: [Shortcut])] = [
        ("Files", [
            Shortcut(title: "New Folder", keys: [["⇧", "⌘", "N"]]),
            Shortcut(title: "Open", keys: [["⌘", "O"], ["⌘", "↓"]]),
            Shortcut(title: "Rename", keys: [["Return"]]),
            Shortcut(title: "Move to Trash, or delete from the phone", keys: [["⌘", "⌫"], ["⌫"]]),
            Shortcut(title: "Quick Look", keys: [["Space"], ["⌘", "Y"]]),
            Shortcut(title: "Show in Finder (Mac)", keys: [["⌥", "⌘", "R"]]),
        ]),
        ("Copying", [
            Shortcut(title: "Download to the Mac", keys: [["⌘", "D"]]),
            Shortcut(title: "Download To…", keys: [["⌥", "⌘", "D"]]),
            Shortcut(title: "Upload Files…", keys: [["⌘", "U"]]),
            Shortcut(title: "Copy, to paste in Finder", keys: [["⌘", "C"]]),
            Shortcut(title: "Add to Clipboard", keys: [["⇧", "⌘", "C"]]),
            Shortcut(title: "Paste files copied in Finder", keys: [["⌘", "V"]]),
            Shortcut(title: "Copy to the other pane (with the Mac pane)", keys: [["⌘", "T"]]),
            Shortcut(title: "Cancel Transfer", keys: [["⌘", "."]]),
        ]),
        ("Getting around", [
            Shortcut(title: "Switch Pane (with the Mac pane)", keys: [["Tab"], ["⌃", "Tab"]]),
            Shortcut(title: "Back / Forward", keys: [["⌘", "["], ["⌘", "]"]]),
            Shortcut(title: "Enclosing Folder", keys: [["⌘", "↑"]]),
            Shortcut(title: "Go to Folder", keys: [["⇧", "⌘", "G"]]),
            Shortcut(title: "Refresh", keys: [["⌘", "R"]]),
        ]),
        ("Selecting", [
            Shortcut(title: "Select All", keys: [["⌘", "A"]]),
            Shortcut(title: "Add or remove one item", keys: [["⌘", "click"]]),
            Shortcut(title: "Select a range", keys: [["⇧", "click"], ["⇧", "arrows"]]),
            Shortcut(title: "Jump to a name", keys: [["type its first letters"]]),
        ]),
        ("View", [
            Shortcut(title: "as Icons / as List", keys: [["⌘", "1"], ["⌘", "2"]]),
            Shortcut(title: "Show Hidden Files", keys: [["⇧", "⌘", "."]]),
            Shortcut(title: "Show Status Bar", keys: [["⌘", "/"]]),
        ]),
        ("Device", [
            Shortcut(title: "Connect or refresh the phone", keys: [["⇧", "⌘", "R"]]),
            Shortcut(title: "Device Info", keys: [["⌘", "I"]]),
            Shortcut(title: "Disconnect", keys: [["⌘", "E"]]),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Self.sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(.headline)
                        ForEach(section.shortcuts) { shortcut in
                            HStack {
                                Text(shortcut.title)
                                Spacer(minLength: 24)
                                ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { index, keys in
                                    if index > 0 {
                                        Text("or").foregroundStyle(.tertiary)
                                    }
                                    HStack(spacing: 3) {
                                        ForEach(keys, id: \.self) { key in
                                            Text(key)
                                                .font(.callout.weight(.medium))
                                                .padding(.horizontal, 6)
                                                .frame(minWidth: 24, minHeight: 22)
                                                .background(.quaternary, in: .rect(cornerRadius: 5))
                                        }
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 520, height: 600)
    }
}

// MARK: - Report a problem

struct ReportProblemView: View {
    @Environment(AppModel.self) private var app

    private enum Status: Equatable {
        case idle
        case working
        case saved(URL)
    }

    @State private var status = Status.idle

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Report a Problem")
                    .font(.title2.weight(.semibold))
                Text("A problem report helps to find out why a phone won’t connect or a transfer fails. It contains the app and macOS versions, what the phone reports about itself, a trace of the connection attempt and the app’s recent log. It contains none of your files or their names beyond what appears in error messages, and it isn’t sent anywhere: you decide who gets it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                step(.cable, "Unlock your phone and connect it with a USB cable.")
                step(.tap, "Choose File Transfer in the phone’s USB notification.")
                step(.bug, "Click Create Report and save the file.")
                step(.link, "Attach the file when you describe the problem.")
            }

            HStack(spacing: 10) {
                Button(status == .working ? "Creating Report…" : "Create Report…") {
                    create()
                }
                .buttonStyle(.borderedProminent)
                .disabled(status == .working || app.transfers.hasWork)

                if status == .working {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                if let url = AppInfo.newIssueURL {
                    Link("Open Issue Tracker", destination: url)
                }
            }

            if case .saved(let url) = status {
                Label("Saved as “\(url.lastPathComponent)”.", symbol: .success)
                    .foregroundStyle(.secondary)
            } else if app.transfers.hasWork {
                Text("Wait for the running transfer to finish first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func step(_ symbol: Symbol, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            symbol.image
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(text)
        }
    }

    private func create() {
        status = .working
        Task {
            let report = await ProblemReport.create(app: app)
            if let url = await ProblemReport.save(report, in: NSApp.keyWindow) {
                status = .saved(url)
            } else {
                status = .idle
            }
        }
    }
}

// MARK: - Software update

struct UpdateView: View {
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 16) {
            switch updates.state {
            case .idle, .checking:
                ProgressView()
                    .controlSize(.large)
                Text("Checking for updates…")
                    .foregroundStyle(.secondary)

            case .upToDate:
                Symbol.success.image
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                Text("\(AppInfo.name) is up to date")
                    .font(.title3.weight(.semibold))
                Text("Version \(AppInfo.version) is the newest version available.")
                    .foregroundStyle(.secondary)
                Button("OK") { dismissWindow(id: WindowID.update) }
                    .keyboardShortcut(.defaultAction)

            case .failed(let message):
                Symbol.failure.image
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text("Couldn’t check for updates")
                    .font(.title3.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { dismissWindow(id: WindowID.update) }
                    Button("Try Again") { Task { await updates.check(userInitiated: true) } }
                        .keyboardShortcut(.defaultAction)
                }

            case .available(let release):
                available(release)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(width: 480)
        .frame(minHeight: 180)
    }

    @ViewBuilder
    private func available(_ release: UpdateChecker.Release) -> some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
        Text("A new version of \(AppInfo.name) is available")
            .font(.title3.weight(.semibold))
        Text("\(release.title) is available — you have \(AppInfo.version).")
            .foregroundStyle(.secondary)

        if !release.notes.isEmpty {
            ScrollView {
                Text((try? AttributedString(
                    markdown: release.notes,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(release.notes))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .textSelection(.enabled)
            }
            .frame(height: 180)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }

        HStack {
            Button("Later") { dismissWindow(id: WindowID.update) }
                .keyboardShortcut(.cancelAction)
            Button("Download") {
                NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
                dismissWindow(id: WindowID.update)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}
