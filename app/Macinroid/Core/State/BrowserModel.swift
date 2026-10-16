import Foundation
import Observation

/// Why a pane cannot show a folder.
enum PaneError: Error, Equatable, Sendable {
    case mac(LocalFileError)
    case phone(DeviceError)

    init(_ error: any Error, path: String) {
        if let error = error as? LocalFileError {
            self = .mac(error)
        } else if let error = error as? DeviceError {
            self = .phone(error)
        } else {
            self = .mac(LocalFileError(error, path: path))
        }
    }

    var title: String {
        switch self {
        case .mac(let error): error.errorDescription ?? "The Folder Can’t Be Opened"
        case .phone(let error): error.title
        }
    }

    var suggestion: String {
        switch self {
        case .mac(let error): error.recoverySuggestion ?? ""
        case .phone(let error): error.suggestion
        }
    }

    var isPermissionProblem: Bool {
        if case .mac(let error) = self { return error.kind == .permissionDenied }
        return false
    }
}

/// The state of one pane: where it is, what is there, and what is selected.
@MainActor
@Observable
final class BrowserModel {
    typealias Lister = @Sendable (_ path: String, _ includeHidden: Bool) async throws -> [FileItem]

    let kind: PaneKind

    private(set) var path: String
    /// The folder's contents in display order, after sorting and filtering.
    private(set) var items: [FileItem] = []
    /// Changes whenever `items` does; cheaper to observe than the array.
    private(set) var revision = 0

    var selection: Set<FileItem.ID> = []

    private(set) var isLoading = false
    private(set) var error: PaneError?
    /// False until a folder has been listed, and while there is nothing to browse.
    private(set) var hasContent = false

    /// Shows only items whose name contains this text.
    var filter = "" { didSet { if filter != oldValue { rebuild() } } }

    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let lister: Lister
    @ObservationIgnored private var allItems: [FileItem] = []
    @ObservationIgnored private var loadToken = 0
    /// Names to select once the next listing arrives.
    @ObservationIgnored private var namesToSelect: Set<String> = []

    init(kind: PaneKind, path: String, settings: AppSettings, lister: @escaping Lister) {
        self.kind = kind
        self.path = FilePath.normalize(path)
        self.settings = settings
        self.lister = lister
    }

    // MARK: Derived state

    var sort: FileSort {
        get { settings.sort(for: kind) }
        set {
            settings.setSort(newValue, for: kind)
            rebuild()
        }
    }

    var viewMode: ViewMode {
        get { settings.viewMode(for: kind) }
        set { settings.setViewMode(newValue, for: kind) }
    }

    var selectedItems: [FileItem] {
        selection.isEmpty ? [] : items.filter { selection.contains($0.id) }
    }

    var canGoUp: Bool { path != FilePath.root }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Every item of the folder, regardless of the filter.
    var unfilteredItems: [FileItem] { allItems }

    var isFiltering: Bool { !filter.isEmpty }

    func item(withID id: FileItem.ID) -> FileItem? {
        items.first { $0.id == id }
    }

    // MARK: Navigation

    /// Opens `path`, remembering the current folder for Back.
    func navigate(to path: String) async {
        let path = FilePath.normalize(path)
        guard path != self.path else {
            await reload()
            return
        }
        backStack.append(self.path)
        forwardStack.removeAll()
        await load(path)
    }

    func goUp() async {
        guard canGoUp else { return }
        // coming back up, the folder that was just left is the natural selection
        namesToSelect = [FilePath.name(of: path)]
        await navigate(to: FilePath.parent(of: path))
    }

    func goBack() async {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        await load(previous)
    }

    func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        await load(next)
    }

    /// Lists the current folder again, keeping the selection where possible.
    func reload(selecting names: Set<String> = []) async {
        if !names.isEmpty { namesToSelect = names }
        await load(path, keepSelection: true)
    }

    /// Forgets everything, as when the phone goes away.
    func reset(to path: String = FilePath.root) {
        loadToken += 1
        self.path = path
        backStack.removeAll()
        forwardStack.removeAll()
        allItems = []
        items = []
        selection = []
        error = nil
        isLoading = false
        hasContent = false
        filter = ""
        revision += 1
    }

    private func load(_ path: String, keepSelection: Bool = false) async {
        loadToken += 1
        let token = loadToken
        let pathChanged = path != self.path

        self.path = path
        isLoading = true
        if pathChanged {
            filter = ""
        }

        let result: Result<[FileItem], any Error>
        do {
            result = .success(try await lister(path, settings.showsHiddenFiles(in: kind)))
        } catch {
            result = .failure(error)
        }

        // a newer request has taken over
        guard token == loadToken else { return }
        isLoading = false

        switch result {
        case .success(let listed):
            allItems = listed
            error = nil
            hasContent = true

            let previous = keepSelection && !pathChanged ? selection : []
            rebuild()
            if !namesToSelect.isEmpty {
                selection = Set(items.filter { namesToSelect.contains($0.name) }.map(\.id))
                namesToSelect = []
            } else {
                selection = previous.intersection(items.map(\.id))
            }

        case .failure(let failure):
            allItems = []
            selection = []
            namesToSelect = []
            self.error = PaneError(failure, path: path)
            hasContent = false
            rebuild()
        }
    }

    /// Applies the sort order and the filter.
    func rebuild() {
        var visible = allItems
        if !filter.isEmpty {
            visible = visible.filter { $0.name.localizedCaseInsensitiveContains(filter) }
            selection.formIntersection(visible.map(\.id))
        }
        items = sort.sorted(visible, foldersFirst: settings.foldersFirst)
        revision += 1
    }

    // MARK: Selection

    func selectAll() {
        selection = Set(items.map(\.id))
    }

    func select(names: Set<String>) {
        selection = Set(items.filter { names.contains($0.name) }.map(\.id))
    }
}
