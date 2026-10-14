import SwiftUI

/// One side of the window: where it is, what is there, and a status line.
struct PaneView: View {
    @Environment(AppModel.self) private var app
    let pane: PaneKind

    var body: some View {
        let browser = app.browser(pane)

        VStack(spacing: 0) {
            PaneHeader(pane: pane)
            Divider()
            content(browser)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if app.settings.showStatusBar {
                Divider()
                PaneStatusBar(pane: pane)
            }
        }
        .background(.background)
        .simultaneousGesture(TapGesture().onEnded { app.activate(pane) })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pane == .mac ? "Mac" : app.session.deviceName)
    }

    @ViewBuilder
    private func content(_ browser: BrowserModel) -> some View {
        if pane == .phone, !app.session.isConnected {
            PhoneConnectionView()
        } else if let error = browser.error {
            PaneErrorView(pane: pane, error: error)
        } else {
            let isBusy = pane == .phone && app.transfers.hasWork

            fileView(browser)
                .overlay {
                    if browser.items.isEmpty, !browser.isLoading, browser.hasContent {
                        emptyFolder(browser)
                            .allowsHitTesting(false)
                    }
                }
                .opacity(isBusy ? 0.45 : 1)
                .allowsHitTesting(!isBusy)
                .overlay {
                    if isBusy {
                        Text("The phone is busy while files are being copied.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .floatingPanel(cornerRadius: 12)
                            .transition(.opacity)
                    }
                }
                .animation(.default, value: isBusy)
        }
    }

    @ViewBuilder
    private func fileView(_ browser: BrowserModel) -> some View {
        let isActive = app.activePane == pane

        switch browser.viewMode {
        case .list:
            FileListView(
                app: app, pane: pane,
                revision: browser.revision, selection: browser.selection, sort: browser.sort, isActive: isActive
            )
        case .grid:
            FileGridView(
                app: app, pane: pane,
                revision: browser.revision, selection: browser.selection, isActive: isActive
            )
        }
    }

    @ViewBuilder
    private func emptyFolder(_ browser: BrowserModel) -> some View {
        if browser.isFiltering {
            ContentUnavailableView.search(text: browser.filter)
        } else {
            ContentUnavailableView {
                Label("This Folder Is Empty", symbol: .folder)
            } description: {
                Text(app.session.isConnected
                    ? "Drag files here, or paste them, to copy them to this folder."
                    : "Nothing to show here.")
            }
        }
    }
}

// MARK: - Header

/// The strip above a pane: which device it is and the path to the current folder.
private struct PaneHeader: View {
    @Environment(AppModel.self) private var app
    let pane: PaneKind

    var body: some View {
        let browser = app.browser(pane)
        let isActive = app.activePane == pane
        // with one pane there is nothing to tell apart
        let showsActiveState = app.settings.showMacPane

        HStack(spacing: 6) {
            deviceLabel
                .fontWeight(.semibold)
                .foregroundStyle(isActive || !showsActiveState ? .primary : .secondary)

            if pane == .mac || app.session.isConnected {
                PathBar(pane: pane)
            }

            Spacer(minLength: 4)

            if browser.isLoading || (pane == .phone && app.session.isConnecting) {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(isActive && showsActiveState ? AnyShapeStyle(.tint.opacity(0.10)) : AnyShapeStyle(.clear))
        .animation(.easeOut(duration: 0.15), value: isActive)
    }

    @ViewBuilder
    private var deviceLabel: some View {
        if pane == .mac {
            Label("Mac", symbol: .mac)
        } else if app.session.isConnected {
            Menu {
                DeviceMenuItems()
            } label: {
                Label(app.session.deviceName, symbol: .phone)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Storage and device options")
        } else {
            Label("Phone", symbol: .phone)
        }
    }
}

/// Storage selection and device actions, shared by the pane header and the Device menu.
struct DeviceMenuItems: View {
    @Environment(AppModel.self) private var app

    var body: some View {
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

            Divider()
        }

        Button("Device Info…") { app.sheet = .deviceInfo }
            .disabled(!session.isConnected)
        Button(session.isConnected ? "Refresh" : "Connect") { app.refresh(.phone) }
        Button("Disconnect") { Task { await session.disconnect() } }
            .disabled(!session.isConnected || app.transfers.isBusy)
    }
}

/// The path to the current folder; every part of it is a button.
private struct PathBar: View {
    @Environment(AppModel.self) private var app
    let pane: PaneKind

    var body: some View {
        let browser = app.browser(pane)
        let paths = FilePath.ancestors(of: browser.path)

        // short paths sit at the leading edge; long ones scroll, showing their end
        ViewThatFits(in: .horizontal) {
            crumbs(paths)
            ScrollView(.horizontal) {
                crumbs(paths)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.trailing)
        }
        .disabled(!app.isAvailable(pane))
    }

    private func crumbs(_ paths: [String]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }

                let isCurrent = index == paths.count - 1
                Button {
                    app.navigate(pane, to: path)
                } label: {
                    Text(title(for: path))
                        .fontWeight(isCurrent ? .medium : .regular)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .contentShape(.rect(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help(path)
            }
        }
        .padding(.vertical, 2)
    }

    private func title(for path: String) -> String {
        guard path == FilePath.root else { return FilePath.name(of: path) }
        return pane == .mac
            ? LocalFileSystem.startupVolumeName
            : app.session.selectedStorage?.displayName ?? "Storage"
    }
}

// MARK: - Status bar

/// The line under a pane: how many items, how much is selected, how much room is left.
private struct PaneStatusBar: View {
    @Environment(AppModel.self) private var app
    let pane: PaneKind

    @State private var macFreeSpace: Int64?

    var body: some View {
        let browser = app.browser(pane)
        let isShowingFiles = pane == .mac || app.session.isConnected

        HStack(spacing: 10) {
            if isShowingFiles, browser.error == nil {
                Text(summary(browser))
                    .lineLimit(1)
            }

            if pane == .phone, let fetch = app.phoneFiles.current {
                HStack(spacing: 6) {
                    ProgressView(value: Double(min(fetch.bytesDone, fetch.bytesTotal)), total: Double(max(fetch.bytesTotal, 1)))
                        .controlSize(.small)
                        .frame(width: 60)
                    Text("Loading “\(fetch.name)” for Quick Look")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .transition(.opacity)
            }

            if let clipboard = app.clipboard, clipboard.source == pane {
                clipboardLabel(clipboard)
            }

            if pane == .phone, let notice = app.notice {
                HStack(spacing: 6) {
                    Label(notice.text, symbol: .success)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if notice.revealPath != nil {
                        Button("Show in Finder") { app.revealNotice() }
                            .buttonStyle(.link)
                    }
                }
                .transition(.opacity)
            }

            Spacer(minLength: 0)

            if pane == .phone, let storage = app.session.selectedStorage, storage.capacity > 0 {
                StorageGauge(storage: storage)
            } else if pane == .mac, let macFreeSpace {
                Text("\(Format.bytes(macFreeSpace)) available")
                    .lineLimit(1)
            }
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .animation(.default, value: app.notice)
        .task(id: browser.path) {
            guard pane == .mac else { return }
            let url = URL(fileURLWithPath: browser.path)
            macFreeSpace = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        }
    }

    @ViewBuilder
    private func clipboardLabel(_ clipboard: FileClipboard) -> some View {
        let count = Format.items(clipboard.paths.count)

        switch app.finderClipboard {
        case .preparing:
            Label("Getting \(count) ready to paste…", symbol: .clipboard)
                .lineLimit(1)
        case .ready:
            Label("\(count) ready to paste in Finder", symbol: .clipboard)
                .lineLimit(1)
                .help("Press ⌘V in Finder, or in another folder of the phone")
        case .empty:
            Label("\(count) on the clipboard", symbol: .clipboard)
                .lineLimit(1)
                .help("Paste in the other pane to copy \(clipboard.paths.count == 1 ? "it" : "them") there")
        }
    }

    private func summary(_ browser: BrowserModel) -> String {
        let total = browser.items.count
        guard !browser.selection.isEmpty else { return Format.items(total) }

        let selected = browser.selectedItems
        var text = "\(selected.count.formatted()) of \(total.formatted()) selected"
        let files = selected.filter { !$0.isFolder }
        if !files.isEmpty, files.count == selected.count {
            text += " · \(Format.bytes(files.reduce(0) { $0 + $1.size }))"
        }
        return text
    }
}

/// How full a storage is.
struct StorageGauge: View {
    let storage: StorageInfo

    var body: some View {
        HStack(spacing: 8) {
            Text("\(Format.bytes(storage.freeSpace)) available of \(Format.bytes(storage.capacity))")
                .lineLimit(1)
            if let fraction = storage.usedFraction {
                Gauge(value: fraction) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(fraction > 0.9 ? .red : .accentColor)
                    .frame(width: 60)
                    .accessibilityLabel("Storage used")
                    .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
            }
        }
        .help("\(storage.displayName): \(Format.bytes(storage.usedSpace)) used")
    }
}

// MARK: - States

/// Shown instead of a listing when a folder cannot be opened.
private struct PaneErrorView: View {
    @Environment(AppModel.self) private var app
    let pane: PaneKind
    let error: PaneError

    var body: some View {
        ContentUnavailableView {
            Label(error.title, symbol: error.isPermissionProblem ? .noAccess : .failure)
        } description: {
            Text(error.suggestion)
        } actions: {
            if error.isPermissionProblem {
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Button("Try Again") { app.refresh(pane) }
            if app.browser(pane).canGoBack {
                Button("Go Back") { app.goBack(pane) }
            }
        }
    }
}

/// Shown in the phone's pane while no phone is connected.
private struct PhoneConnectionView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let session = app.session

        ScrollView {
            VStack(spacing: 18) {
                switch session.state {
                case .connecting:
                    ProgressView()
                        .controlSize(.large)
                    Text("Looking for your phone…")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                case .failed(let error):
                    stateIcon(symbol(for: error))
                    VStack(spacing: 6) {
                        Text(error.title)
                            .font(.title2.weight(.semibold))
                        Text(error.suggestion)
                            .foregroundStyle(.secondary)
                    }
                    conflictingApps
                    actions

                default:
                    stateIcon(.cable)
                    Text("Connect Your Android Phone")
                        .font(.title2.weight(.semibold))
                    steps
                    conflictingApps
                    actions
                    Text(app.settings.connectAutomatically
                        ? "Macinroid connects as soon as your phone is ready."
                        : "Click Connect once your phone is ready.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
    }

    private func stateIcon(_ symbol: Symbol) -> some View {
        symbol.image
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(.tint)
            .symbolRenderingMode(.hierarchical)
            .accessibilityHidden(true)
    }

    private func symbol(for error: DeviceError) -> Symbol {
        switch error.code {
        case .deviceLocked: .locked
        case .allowStorageAccess: .tap
        case .multipleDevice: .multiple
        default: .failure
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, "Unlock your phone and connect it to your Mac with a USB cable.")
            step(2, "On the phone, tap the **Charging this device via USB** notification.")
            step(3, "Under **Use USB for**, choose **File Transfer**.")
        }
        .multilineTextAlignment(.leading)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
                .background(.tint.opacity(0.14), in: .circle)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var conflictingApps: some View {
        let names = app.session.conflictingApps.compactMap(\.localizedName)
        if let name = names.first {
            VStack(spacing: 8) {
                Label("\(name) is running and may be keeping the phone to itself.", symbol: .failure)
                    .symbolRenderingMode(.multicolor)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Quit \(name)") {
                    app.session.quitConflictingApps()
                    app.session.connectPersistently(attempts: 4)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Connect") { app.refresh(.phone) }
                .buttonStyle(.borderedProminent)
            Button("Connection Help") { openWindow(id: WindowID.help) }
        }
        .controlSize(.large)
    }
}
