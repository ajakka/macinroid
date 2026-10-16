import SwiftUI

/// The main window: a sidebar of places, the phone's files — next to the Mac's,
/// if the user wants both — and the running transfer along the bottom.
struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.openWindow) private var openWindow

    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showsTransfers = false

    var body: some View {
        @Bindable var app = app

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 280)
        } detail: {
            // the transfer gets room of its own, so that it never covers files
            VStack(spacing: 0) {
                panes
                TransferBar()
            }
            .animation(.snappy(duration: 0.3), value: app.transfers.active?.id)
        }
        .navigationTitle(AppInfo.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .searchable(text: filter, placement: .toolbar, prompt: "Filter")
        .sheet(item: $app.sheet) { sheet in
            Group {
                switch sheet {
                case .newFolder(let pane):
                    NameSheet(pane: pane, purpose: .newFolder)
                case .rename(let pane, let item):
                    NameSheet(pane: pane, purpose: .rename(item))
                case .goToFolder(let pane):
                    GoToFolderSheet(pane: pane)
                case .deviceInfo:
                    DeviceInfoSheet()
                }
            }
            .environment(app)
        }
        .background(WindowAccessor { app.window = $0 })
        .onChange(of: dockProgress) { _, fraction in
            TransferFeedback.setDockProgress(fraction)
        }
        .onChange(of: app.settings.showMacPane) { _, isShown in
            if isShown {
                app.refresh(.mac)
            } else {
                app.activePane = .phone
            }
        }
        .onChange(of: app.settings.foldersFirst) {
            app.sortingPreferencesChanged()
        }
        .task {
            guard !AppEnvironment.isRunningTests else { return }
            app.start()
            if app.settings.lastWelcomeVersion != AppInfo.version {
                openWindow(id: WindowID.welcome)
            }
            if await updates.checkAutomatically() != nil {
                openWindow(id: WindowID.update)
            }
        }
    }

    // MARK: Panes

    @ViewBuilder
    private var panes: some View {
        let settings = app.settings

        if settings.showMacPane {
            HSplitView {
                if settings.macPaneOnLeft {
                    pane(.mac)
                    pane(.phone)
                } else {
                    pane(.phone)
                    pane(.mac)
                }
            }
        } else {
            // the phone by itself; files travel to and from Finder
            pane(.phone)
        }
    }

    private func pane(_ kind: PaneKind) -> some View {
        PaneView(pane: kind)
            .frame(minWidth: 300, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var subtitle: String {
        switch app.session.state {
        case .connected(let device):
            if let storage = app.session.selectedStorage, app.session.storages.count > 1 {
                "\(device.displayName) — \(storage.displayName)"
            } else {
                device.displayName
            }
        case .connecting:
            "Connecting…"
        case .failed(let error):
            error.title
        case .disconnected:
            "No phone connected"
        }
    }

    /// The search field filters the pane that has the focus.
    private var filter: Binding<String> {
        Binding {
            app.activeBrowser.filter
        } set: {
            app.activeBrowser.filter = $0
        }
    }

    private var dockProgress: Double? {
        guard let job = app.transfers.active else { return nil }
        return job.phase == .copying ? job.progress.fraction ?? job.progress.fileFraction : 0
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let pane = app.activePane
        let browser = app.activeBrowser
        let isAvailable = app.isAvailable(pane)
        let canAct = isAvailable && browser.error == nil

        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button {
                    app.goBack(pane)
                } label: {
                    Label("Back", symbol: .back)
                }
                .disabled(!isAvailable || !browser.canGoBack)

                Button {
                    app.goForward(pane)
                } label: {
                    Label("Forward", symbol: .forward)
                }
                .disabled(!isAvailable || !browser.canGoForward)
            }
            .help("Go back or forward in the \(app.title(for: pane)) pane")
        }

        ToolbarItem {
            Picker("View", selection: Binding(get: { browser.viewMode }, set: { browser.viewMode = $0 })) {
                ForEach(ViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbolName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Show items as a list or as icons")
        }

        ToolbarItemGroup {
            Button {
                app.requestNewFolder(in: pane)
            } label: {
                Label("New Folder", symbol: .newFolder)
            }
            .disabled(!canAct)
            .help("Create a folder in the \(app.title(for: pane)) pane")

            Button {
                app.deleteSelection(in: pane)
            } label: {
                Label(pane == .mac ? "Move to Trash" : "Delete", symbol: .trash)
            }
            .disabled(!canAct || browser.selection.isEmpty)
            .help(pane == .mac ? "Move the selected items to the Trash" : "Delete the selected items from the phone")

            Button {
                app.refresh(pane)
            } label: {
                Label("Refresh", symbol: .refresh)
            }
            .help(pane == .phone && !app.session.isConnected ? "Look for a phone" : "Reload the \(app.title(for: pane)) pane")
        }

        if app.settings.showMacPane {
            ToolbarItem {
                let target = app.title(for: pane.other)
                let pointsRight = (pane == .mac) == app.settings.macPaneOnLeft

                Button {
                    app.copySelectionToOtherPane(from: pane)
                } label: {
                    Label("Copy to \(target)", symbol: pointsRight ? .copyRight : .copyLeft)
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!app.canCopyToOtherPane(from: pane))
                .help("Copy the selected items to the folder shown in the \(target) pane")
            }
        } else {
            ToolbarItemGroup {
                Button {
                    app.chooseFilesToUpload()
                } label: {
                    Label("Upload", symbol: .uploads)
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!app.canUpload())
                .help("Copy files from your Mac to this folder on the phone")

                Menu {
                    Button("Download to “\(app.settings.downloadFolderName)”") { app.downloadSelection() }
                    Button("Download To…") { app.chooseFolderAndDownloadSelection() }
                } label: {
                    Label("Download", symbol: .downloads)
                        .labelStyle(.titleAndIcon)
                } primaryAction: {
                    app.downloadSelection()
                }
                .disabled(!app.canDownloadSelection())
                .help("Save the selected items to “\(app.settings.downloadFolderName)” on your Mac")
            }
        }

        ToolbarItem {
            Button {
                showsTransfers.toggle()
            } label: {
                Label("Transfers", symbol: .transfers)
                    .symbolEffect(.pulse, isActive: app.transfers.isBusy)
            }
            .help("Show transfers")
            .popover(isPresented: $showsTransfers, arrowEdge: .bottom) {
                TransfersPopover()
                    .environment(app)
            }
        }
    }
}

/// Hands the window that hosts the view to a closure.
private struct WindowAccessor: NSViewRepresentable {
    let onChange: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class TrackingView: NSView {
        var onChange: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange?(window)
        }
    }
}
