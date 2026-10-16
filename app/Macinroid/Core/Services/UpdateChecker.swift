import Foundation
import Observation

/// Looks for newer releases of the app on GitHub.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Equatable, Sendable {
        var version: String
        var title: String
        var notes: String
        var pageURL: URL
        /// The disk image or archive to download, when the release has one.
        var downloadURL: URL?
        var isPrerelease: Bool
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    private(set) var state: State = .idle

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let repository: String?
    @ObservationIgnored private let session: URLSession

    /// How long after launch the automatic check runs.
    static let automaticCheckDelay: Duration = .seconds(10)

    init(settings: AppSettings, repository: String? = AppInfo.repository, session: URLSession = .shared) {
        self.settings = settings
        self.repository = repository
        self.session = session
    }

    /// Whether there is a place to look for updates at all.
    var isAvailable: Bool { repository != nil }

    /// Checks once, shortly after launch, if the user wants that.
    /// Returns the release to offer, if there is one.
    func checkAutomatically() async -> Release? {
        guard settings.checkForUpdatesAutomatically, isAvailable else { return nil }
        guard (try? await Task.sleep(for: Self.automaticCheckDelay)) != nil, state == .idle else { return nil }

        await check(userInitiated: false)
        if case .available(let release) = state { return release }
        return nil
    }

    func check(userInitiated: Bool) async {
        guard let repository, state != .checking else { return }
        state = .checking

        do {
            let releases = try await fetchReleases(repository)
            let newest = Self.newestRelease(in: releases, after: AppInfo.version, includingPrereleases: settings.includeBetaUpdates)
            state = newest.map(State.available) ?? .upToDate
        } catch is CancellationError {
            state = .idle
        } catch let error as URLError where error.code == .cancelled {
            state = .idle
        } catch {
            Log.error("update check failed: \(error.localizedDescription)")
            // a failed background check is not worth interrupting anyone for
            state = userInitiated ? .failed(Self.message(for: error)) : .idle
        }
    }

    // MARK: GitHub

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
        }

        var tag_name: String
        var name: String?
        var body: String?
        var html_url: URL
        var draft: Bool
        var prerelease: Bool
        var assets: [Asset]

        var release: Release {
            let download = assets.first { $0.name.hasSuffix(".dmg") } ?? assets.first { $0.name.hasSuffix(".zip") }
            return Release(
                version: tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                title: name?.isEmpty == false ? name! : tag_name,
                notes: body ?? "",
                pageURL: html_url,
                downloadURL: download?.browser_download_url,
                isPrerelease: prerelease
            )
        }
    }

    private func fetchReleases(_ repository: String) async throws -> [Release] {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
        // a repository without releases is simply up to date
        if status == 404 { return [] }
        guard status == 200 else { throw URLError(.badServerResponse) }

        return try JSONDecoder().decode([GitHubRelease].self, from: data).filter { !$0.draft }.map(\.release)
    }

    private static func message(for error: any Error) -> String {
        if let error = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .timedOut, .dnsLookupFailed].contains(error.code) {
            return "Your Mac isn’t connected to the internet."
        }
        return "The update server couldn’t be reached. Try again later."
    }

    // MARK: Versions

    /// The highest release above `current`, or nil when `current` is the newest.
    static func newestRelease(in releases: [Release], after current: String, includingPrereleases: Bool) -> Release? {
        releases
            .filter { includingPrereleases || !$0.isPrerelease }
            .filter { isVersion($0.version, newerThan: current) }
            .max { isVersion($1.version, newerThan: $0.version) }
    }

    /// Compares dotted versions number by number; "1.10" is newer than "1.9".
    /// With equal numbers, a version without a suffix beats one with ("1.2" > "1.2-beta.1").
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parse(_ version: String) -> (numbers: [Int], suffix: String) {
            let parts = version.split(separator: "-", maxSplits: 1)
            let numbers = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            return (numbers, parts.count > 1 ? String(parts[1]) : "")
        }

        let a = parse(candidate), b = parse(current)
        for index in 0..<max(a.numbers.count, b.numbers.count) {
            let x = index < a.numbers.count ? a.numbers[index] : 0
            let y = index < b.numbers.count ? b.numbers[index] : 0
            if x != y { return x > y }
        }
        if a.suffix.isEmpty != b.suffix.isEmpty { return a.suffix.isEmpty }
        return a.suffix.compare(b.suffix, options: .numeric) == .orderedDescending
    }
}
