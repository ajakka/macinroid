import SwiftUI

/// Shortcuts to places on the Mac and on the phone.
struct SidebarView: View {
    @Environment(AppModel.self) private var app

    /// A place the sidebar can take a pane to.
    private enum Place: Hashable {
        case mac(String)
        case phone(storage: UInt32, path: String)
    }

    private struct Favorite: Identifiable {
        var name: String
        var symbol: Symbol
        var path: String
        var id: String { path }
    }

    private static let favorites: [Favorite] = {
        let home = LocalFileSystem.homePath
        return [
            Favorite(name: "Home", symbol: .home, path: home),
            Favorite(name: "Desktop", symbol: .desktop, path: home + "/Desktop"),
            Favorite(name: "Documents", symbol: .documents, path: home + "/Documents"),
            Favorite(name: "Downloads", symbol: .downloads, path: home + "/Downloads"),
            Favorite(name: "Pictures", symbol: .pictures, path: home + "/Pictures"),
            Favorite(name: "Movies", symbol: .movies, path: home + "/Movies"),
            Favorite(name: "Music", symbol: .music, path: home + "/Music"),
        ]
    }()

    var body: some View {
        List(selection: selection) {
            if app.settings.showMacPane {
                Section("Mac") {
                    ForEach(Self.favorites) { favorite in
                        Label(favorite.name, symbol: favorite.symbol)
                            .tag(Place.mac(favorite.path))
                    }
                }

                Section("Locations") {
                    Label(LocalFileSystem.startupVolumeName, symbol: .internalStorage)
                        .tag(Place.mac(FilePath.root))
                    ForEach(app.volumes, id: \.path) { volume in
                        Label(volume.name, symbol: volume.isEjectable ? .externalDrive : .internalStorage)
                            .tag(Place.mac(volume.path))
                    }
                }
            }

            Section(app.session.isConnected ? app.session.deviceName : "Phone") {
                if app.session.isConnected {
                    ForEach(app.session.storages) { storage in
                        Label(storage.displayName, symbol: storage.isRemovable ? .sdCard : .phone)
                            .tag(Place.phone(storage: storage.id, path: FilePath.root))
                    }
                    if let storage = app.session.selectedStorageID {
                        ForEach(app.phoneShortcuts, id: \.self) { folder in
                            Label(folder, symbol: symbol(forPhoneFolder: folder))
                                .tag(Place.phone(storage: storage, path: "/" + folder))
                        }
                    }
                } else {
                    Label(app.session.isConnecting ? "Connecting…" : "Not Connected", symbol: .cable)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// The sidebar highlights where the active pane is, and navigates when a row is picked.
    private var selection: Binding<Place?> {
        Binding {
            switch app.activePane {
            case .mac:
                return .mac(app.mac.path)
            case .phone:
                guard let storage = app.session.selectedStorageID, app.session.isConnected else { return nil }
                return .phone(storage: storage, path: app.phone.path)
            }
        } set: { place in
            switch place {
            case .mac(let path):
                app.navigate(.mac, to: path)
            case .phone(let storage, let path):
                guard app.isAvailable(.phone) else { return }
                if storage != app.session.selectedStorageID {
                    app.selectStorage(storage)
                }
                app.navigate(.phone, to: path)
            case nil:
                break
            }
        }
    }

    private func symbol(forPhoneFolder name: String) -> Symbol {
        switch name {
        case "DCIM": .camera
        case "Pictures": .pictures
        case "Download": .downloads
        case "Documents": .documents
        case "Movies": .movies
        case "Music": .music
        default: .folder
        }
    }
}
