import SwiftUI

/// Asks for the name of a new folder, or a new name for an item.
struct NameSheet: View {
    enum Purpose: Equatable {
        case newFolder
        case rename(FileItem)
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let pane: PaneKind
    let purpose: Purpose

    @State private var name = ""
    @State private var problem: FileNameRule.Problem?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 6) {
                SelectingTextField(
                    text: $name,
                    placeholder: purpose == .newFolder ? "Folder name" : "Name",
                    selectsBaseName: purpose != .newFolder,
                    onSubmit: submit
                )
                .frame(height: 22)
                .accessibilityLabel("Name")

                if let problem {
                    Label(problem.message, symbol: .failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if pane == .phone, purpose != .newFolder {
                    Text("Some phones don’t allow items to be renamed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(purpose == .newFolder ? "Create" : "Rename", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if case .rename(let item) = purpose {
                name = item.name
            } else {
                name = unusedFolderName()
            }
        }
        .onChange(of: name) { problem = nil }
    }

    private var title: String {
        switch purpose {
        case .newFolder:
            "New Folder"
        case .rename(let item):
            "Rename “\(item.name)”"
        }
    }

    private var subtitle: String {
        let browser = app.browser(pane)
        let location = browser.path == FilePath.root ? app.title(for: pane) : "“\(FilePath.name(of: browser.path))” on \(app.title(for: pane))"
        return purpose == .newFolder ? "Create a folder in \(location)." : "In \(location)."
    }

    private var renamedItem: FileItem? {
        if case .rename(let item) = purpose { return item }
        return nil
    }

    /// "untitled folder", "untitled folder 2", … as Finder names them.
    private func unusedFolderName() -> String {
        let taken = Set(app.browser(pane).unfilteredItems.map { $0.name.lowercased() })
        var candidate = "untitled folder"
        var number = 2
        while taken.contains(candidate) {
            candidate = "untitled folder \(number)"
            number += 1
        }
        return candidate
    }

    private func submit() {
        guard !isWorking else { return }

        if let problem = app.problem(withName: name, in: pane, renaming: renamedItem) {
            self.problem = problem
            return
        }

        isWorking = true
        Task {
            let succeeded: Bool
            if let item = renamedItem {
                succeeded = await app.rename(item, to: name, in: pane)
            } else {
                succeeded = await app.createFolder(named: name, in: pane)
            }
            isWorking = false
            // on failure the app has explained why; either way the sheet is done
            _ = succeeded
            dismiss()
        }
    }
}

/// A text field that starts out focused with its text selected — for a
/// file name, without the extension, the way Finder begins a rename.
private struct SelectingTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var selectsBaseName: Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }

        // the sheet's window may only exist a moment after the first update
        let coordinator = context.coordinator
        let selectsBaseName = selectsBaseName
        DispatchQueue.main.async {
            guard !coordinator.didFocus, !field.stringValue.isEmpty, let window = field.window else { return }
            coordinator.didFocus = true
            window.makeFirstResponder(field)

            let name = field.stringValue as NSString
            let baseLength = (name.deletingPathExtension as NSString).length
            let length = selectsBaseName && baseLength > 0 ? baseLength : name.length
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: length)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SelectingTextField
        var didFocus = false

        init(_ parent: SelectingTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}

/// Asks for a path to open in a pane.
struct GoToFolderSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let pane: PaneKind

    @State private var path = ""
    @State private var problem: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Go to Folder on \(app.title(for: pane))")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Path", text: $path, prompt: Text(pane == .mac ? "~/Documents" : "/DCIM/Camera"))
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit(go)
                if let problem {
                    Label(problem, symbol: .failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            path = app.browser(pane).path
            isFocused = true
        }
        .onChange(of: path) { problem = nil }
    }

    private func go() {
        var target = path.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }

        if pane == .mac {
            target = (target as NSString).expandingTildeInPath
            guard LocalFileSystem.isDirectory(target) else {
                problem = "That folder can’t be found."
                return
            }
        }
        app.navigate(pane, to: target)
        dismiss()
    }
}

/// What the connected phone says about itself.
struct DeviceInfoSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let device = app.session.device {
                Form {
                    Section {
                        LabeledContent("Name", value: device.displayName)
                        if !device.manufacturer.isEmpty {
                            LabeledContent("Manufacturer", value: device.manufacturer)
                        }
                        if !device.mtp.deviceVersion.isEmpty {
                            LabeledContent("Software Version", value: device.mtp.deviceVersion)
                        }
                        if !device.serialNumber.isEmpty {
                            LabeledContent("Serial Number", value: device.serialNumber)
                        }
                    } header: {
                        Label("Device", symbol: .phone)
                    }

                    Section {
                        ForEach(app.session.storages) { storage in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label(storage.displayName, symbol: storage.isRemovable ? .sdCard : .internalStorage)
                                    Spacer()
                                    Text("\(Format.bytes(storage.freeSpace)) available of \(Format.bytes(storage.capacity))")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                if let fraction = storage.usedFraction {
                                    ProgressView(value: fraction)
                                        .tint(fraction > 0.9 ? .red : .accentColor)
                                        .accessibilityLabel("\(storage.displayName) used")
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Label("Storage", symbol: .internalStorage)
                    }

                    Section {
                        LabeledContent("USB ID", value: String(format: "%04X:%04X", device.usb.vendorId, device.usb.productId))
                        LabeledContent("MTP Version", value: String(format: "%.2f", Double(device.mtp.mtpVersion) / 100))
                        if !device.mtp.mtpExtension.isEmpty {
                            LabeledContent("Extensions", value: device.mtp.mtpExtension)
                        }
                    } header: {
                        Label("Connection", symbol: .cable)
                    }
                }
                .formStyle(.grouped)
                .textSelection(.enabled)
            } else {
                ContentUnavailableView("No Phone Connected", systemImage: Symbol.cable.rawValue)
                    .frame(height: 200)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 440)
    }
}
