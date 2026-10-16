import SwiftUI

/// Shown on first launch and after an update: what the app does.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow

    private struct Feature: Identifiable {
        var symbol: Symbol
        var title: String
        var detail: String
        var id: String { title }
    }

    private static let features = [
        Feature(symbol: .cable, title: "Plug in and go",
                detail: "Connect an Android phone with a USB cable and its files show up — no setup, no account."),
        Feature(symbol: .speed, title: "Fast, and built for big files",
                detail: "Copy whole folders and files larger than 4 GB in one go, with progress, speed and time remaining."),
        Feature(symbol: .dragDrop, title: "Works with Finder",
                detail: "Drag from the phone straight to Finder or the desktop, drop files onto the phone, or copy here and paste there."),
        Feature(symbol: .cancel, title: "Stay in control",
                detail: "Cancel a transfer at any time, or queue up several and let them run one after the other."),
        Feature(symbol: .sdCard, title: "Internal storage and SD card",
                detail: "Switch between the phone’s storages from the sidebar or the device menu."),
        Feature(symbol: .keyboard, title: "At home on the Mac",
                detail: "List and icon views, Quick Look, the Trash, familiar shortcuts, light and dark appearance."),
        Feature(symbol: .privacy, title: "Private by design",
                detail: "Macinroid collects nothing. Your files go from your phone to your Mac and nowhere else."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)
                Text("Welcome to \(AppInfo.name)")
                    .font(.largeTitle.weight(.bold))
                Text("Move files between your Mac and your Android phone.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 30)
            .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(Self.features) { feature in
                    HStack(alignment: .top, spacing: 14) {
                        feature.symbol.image
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(.headline)
                            Text(feature.detail)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 40)

            Button {
                app.settings.lastWelcomeVersion = AppInfo.version
                dismissWindow(id: WindowID.welcome)
            } label: {
                Text("Get Started")
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 26)
            .padding(.bottom, 28)
        }
        .frame(width: 560)
        .onDisappear {
            app.settings.lastWelcomeVersion = AppInfo.version
        }
    }
}
