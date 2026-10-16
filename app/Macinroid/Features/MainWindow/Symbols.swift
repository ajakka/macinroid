import SwiftUI

/// The SF Symbols the app uses, in one place so that a test can check that
/// each of them exists on the oldest macOS the app runs on.
enum Symbol: String, CaseIterable {
    case mac = "laptopcomputer"
    case phone = "smartphone"
    case cable = "cable.connector"
    case internalStorage = "internaldrive"
    case sdCard = "sdcard"
    case externalDrive = "externaldrive"

    case home = "house"
    case desktop = "menubar.dock.rectangle"
    case documents = "doc"
    case downloads = "arrow.down.circle"
    case uploads = "arrow.up.circle"
    case pictures = "photo"
    case movies = "film"
    case music = "music.note"
    case folder = "folder"
    case camera = "camera"

    case back = "chevron.left"
    case forward = "chevron.right"
    case up = "arrow.up"
    case refresh = "arrow.clockwise"
    case newFolder = "folder.badge.plus"
    case trash = "trash"
    case copyRight = "arrow.right"
    case copyLeft = "arrow.left"
    case upload = "arrow.up.circle.fill"
    case download = "arrow.down.circle.fill"
    case transfers = "arrow.up.arrow.down"
    case clipboard = "doc.on.clipboard"
    case list = "list.bullet"
    case stop = "xmark.circle.fill"
    case help = "questionmark.circle"

    case success = "checkmark.circle.fill"
    case failure = "exclamationmark.triangle.fill"
    case cancelled = "minus.circle.fill"
    case waiting = "clock"
    case locked = "lock.fill"
    case tap = "hand.tap"
    case multiple = "rectangle.on.rectangle"
    case noAccess = "hand.raised"
    case search = "magnifyingglass"

    case speed = "speedometer"
    case dragDrop = "square.and.arrow.down.on.square"
    case keyboard = "keyboard"
    case cancel = "stop.circle"
    case privacy = "hand.raised.slash"
    case gear = "gearshape"
    case bug = "ladybug"
    case link = "arrow.up.right.square"

    var image: Image { Image(systemName: rawValue) }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: String, symbol: Symbol) {
        self.init(title, systemImage: symbol.rawValue)
    }
}

extension View {
    /// A floating surface: Liquid Glass where the system has it, a material elsewhere.
    @ViewBuilder
    func floatingPanel(cornerRadius: CGFloat = 16) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator.opacity(0.6)))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        }
    }
}
