import AppKit
import Foundation
import Observation
import os
import PinwallCore
import ServiceManagement

/// A finished wallpaper in the output folder (from a pin or one of the user's own images).
struct Wallpaper: Identifiable, Hashable {
    let url: URL
    let modified: Date
    /// Set when the file came from a Pinterest pin.
    let record: PinRecord?

    var id: URL { url }
    var isLowRes: Bool { record?.note.contains("low-res") ?? false }

    static func == (a: Wallpaper, b: Wallpaper) -> Bool { a.url == b.url && a.modified == b.modified }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

@MainActor
@Observable
final class AppModel {
    enum Account: Equatable {
        case unknown
        case loggedOut
        case loggedIn(String)

        var username: String? { if case .loggedIn(let name) = self { name } else { nil } }
    }

    enum Activity: Equatable {
        case idle
        case checking
        case processing(done: Int, total: Int)
        case fitting(done: Int, total: Int)
    }

    // MARK: State

    private(set) var account: Account = .unknown
    private(set) var activity: Activity = .idle
    private(set) var boards: [Board] = []
    private(set) var wallpapers: [Wallpaper] = []
    private(set) var skippedPins: [PinRecord] = []
    private(set) var lastSync: Date?
    private(set) var lastResult: String?
    private(set) var errorMessage: String?
    /// Set when a freshly linked board already has pins: ask before importing them all.
    private(set) var pendingImport: [Pin]?
    private(set) var upscaler: Upscaler?
    private(set) var target: PixelSize

    // MARK: Settings

    var board: Board? {
        didSet {
            store(board, key: "board")
            pendingImport = nil
        }
    }

    var outputFolder: URL {
        didSet {
            defaults.set(outputFolder.path(percentEncoded: false), forKey: "outputFolder")
            skippedLocalFiles = []
            reloadWallpapers()
        }
    }

    /// Also crop/upscale images the user put in the output folder themselves. Off by default:
    /// it moves originals out of the folder.
    var fitOwnImages: Bool {
        didSet { defaults.set(fitOwnImages, forKey: "fitOwnImages") }
    }

    var upscaleModel: UpscaleModel {
        didSet { store(upscaleModel, key: "upscaleModel") }
    }

    /// A single wallpaper the user set directly; rotation is paused on that desktop until resumed.
    var pinnedWallpaper: URL? {
        didSet { defaults.set(pinnedWallpaper?.path(percentEncoded: false), forKey: "pinnedWallpaper") }
    }

    var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: "hasCompletedSetup") }
    }

    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    errorMessage = "Couldn't change Open at Login: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Hooks set by the app delegate

    @ObservationIgnored var presentLogin: () -> Void = {}
    @ObservationIgnored var presentSetup: () -> Void = {}
    @ObservationIgnored var presentSettings: () -> Void = {}

    // MARK: Internals

    let session: PinterestSession
    let isDemo: Bool
    private var library: Library
    /// Own images left alone this session (wrong shape / failed), so they aren't retried every sync.
    @ObservationIgnored private var skippedLocalFiles: Set<String> = []
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "Pinwall", category: "sync")
    /// Upper bound on pages fetched per sync (25 pins each).
    private let maxPages = 10

    static let supportFolder = URL.applicationSupportDirectory.appending(path: "Pinwall")
    static let defaultOutputFolder = URL.picturesDirectory.appending(path: "Pinwall", directoryHint: .isDirectory)

    init(defaults: UserDefaults = .standard, libraryFile: URL = AppModel.supportFolder.appending(path: "library.json"),
         demo: Bool = false) {
        self.defaults = defaults
        isDemo = demo
        session = PinterestSession()
        library = Library(file: libraryFile)
        outputFolder = defaults.string(forKey: "outputFolder").map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? Self.defaultOutputFolder
        board = Self.load(Board.self, key: "board", from: defaults)
        fitOwnImages = defaults.object(forKey: "fitOwnImages") as? Bool ?? false
        upscaleModel = Self.load(UpscaleModel.self, key: "upscaleModel", from: defaults) ?? .automatic
        // Existing installs (board already linked) skip the setup window.
        hasCompletedSetup = defaults.object(forKey: "hasCompletedSetup") as? Bool
            ?? (defaults.data(forKey: "board") != nil)
        pinnedWallpaper = defaults.string(forKey: "pinnedWallpaper").map { URL(filePath: $0) }
        upscaler = Upscaler.locate()
        target = Screens.largestPixelSize()
        if !demo {
            session.onNavigationFinished = { [weak self] url in
                Task { await self?.navigationFinished(url) }
            }
            reloadWallpapers()
        }
    }

    var isBusy: Bool { activity != .idle }
    var installedModels: [String] { upscaler?.installedModels ?? [] }

    // MARK: Lifecycle

    /// Launch and menu open: check login, then sync if a board is linked.
    func refresh() async {
        guard !isDemo else { return }
        log.info("refresh requested (busy: \(self.isBusy))")
        target = Screens.largestPixelSize()
        reloadWallpapers()
        guard !isBusy else { return }
        if case .loggedIn = account, let lastSync, Date.now.timeIntervalSince(lastSync) < 20 { return }
        await checkAccount()
        if case .loggedIn = account, board != nil, pendingImport == nil, hasCompletedSetup { await sync() }
    }

    func checkAccount() async {
        guard !isDemo else { return }
        do {
            if let name = try await session.username() {
                if account != .loggedIn(name) {
                    account = .loggedIn(name)
                    await loadBoards()
                }
            } else {
                account = .loggedOut
            }
            errorMessage = nil
        } catch {
            errorMessage = "Can't reach Pinterest: \(error)"
            log.error("account check failed: \(String(describing: error), privacy: .public)")
        }
    }

    func loadBoards() async {
        guard !isDemo, case .loggedIn(let name) = account else { return }
        do {
            boards = try await session.boards(username: name)
            log.info("loaded \(self.boards.count) boards")
            if let board, let fresh = boards.first(where: { $0.id == board.id }), fresh != board { self.board = fresh }
        } catch {
            errorMessage = "Couldn't load boards: \(error)"
        }
    }

    func logOut() async {
        await session.logOut()
        account = .loggedOut
        boards = []
    }

    func refreshUpscaler() {
        upscaler = Upscaler.locate()
    }

    /// Login page navigations: once Pinterest leaves the login page, check whether we're in.
    private func navigationFinished(_ url: URL?) async {
        guard account == .loggedOut, let path = url?.path(percentEncoded: false), !path.contains("login") else { return }
        await checkAccount()
    }

    // MARK: Board

    /// Links a board. When it already has pins, `pendingImport` asks whether to import them.
    func choose(_ board: Board) async {
        guard self.board?.id != board.id else { return }
        self.board = board
        await sync(linking: true)
    }

    func importExisting(_ include: Bool) async {
        guard let pins = pendingImport else { return }
        pendingImport = nil
        if include {
            lastResult = await process(pins).joined(separator: " · ")
        } else {
            let records = pins.map { PinRecord(pin: $0, status: .skippedExisting, note: "Was on the board before linking") }
            try? library.save(records)
            lastResult = "Only pins added from now on will be imported"
        }
        reloadWallpapers()
    }

    // MARK: Sync

    func sync(linking: Bool = false) async {
        guard !isDemo, !isBusy, let board else { return }
        activity = .checking
        errorMessage = nil
        defer { if activity == .checking { activity = .idle } }

        do {
            var pins: [Pin] = [], unusable: [Pin] = []
            var bookmark: String?
            for _ in 0..<maxPages {
                let page = try await session.boardPage(boardID: board.id, bookmark: bookmark)
                pins += page.pins
                unusable += page.unusable
                bookmark = page.bookmark
                if bookmark == nil { break }
            }
            lastSync = .now

            let newUnusable = unusable.filter { !library.isSeen($0.id) }
            try library.save(newUnusable.map {
                PinRecord(pin: $0, status: .skippedNotImage, note: "Video or idea pin without an image")
            })

            var seenIDs = Set<String>()
            let fresh = pins.filter { !library.isSeen($0.id) && seenIDs.insert($0.id).inserted }
            log.info("board \(board.name, privacy: .public): \(pins.count) pins, \(fresh.count) new")

            if linking, !fresh.isEmpty {
                pendingImport = fresh
                activity = .idle
                return
            }
            var summary = fresh.isEmpty ? [] : await process(fresh)
            if fitOwnImages { summary += await fitLocalImages() }
            lastResult = summary.isEmpty ? "Up to date" : summary.joined(separator: " · ")
            activity = .idle
        } catch SessionError.http(let status, _) where status == 401 || status == 403 {
            account = .loggedOut
            activity = .idle
        } catch {
            errorMessage = "Sync failed: \(error)"
            activity = .idle
        }
        reloadWallpapers()
    }

    private var pipelineOptions: PipelineOptions {
        var options = PipelineOptions(
            target: target,
            outputFolder: outputFolder,
            workFolder: URL.cachesDirectory.appending(path: "Pinwall/work"),
            upscaler: upscaler)
        options.model = upscaleModel
        return options
    }

    /// Processes board pins; returns summary parts like ["2 added", "1 skipped"].
    private func process(_ pins: [Pin]) async -> [String] {
        let options = pipelineOptions
        var added = 0, skipped = 0, failed = 0
        for (index, pin) in pins.enumerated() {
            activity = .processing(done: index, total: pins.count)
            let record: PinRecord
            do {
                // Vision, Core Image and upscayl-bin block: keep them off the main actor.
                record = try await Task.detached(priority: .userInitiated) {
                    try await Pipeline.process(pin, options: options).record
                }.value
            } catch {
                record = PinRecord(pin: pin, status: .failed, note: "\(error)")
            }
            switch record.status {
            case .done: added += 1
            case .failed: failed += 1
            default: skipped += 1
            }
            try? library.save(record)
            reloadWallpapers()
        }
        activity = .idle
        var parts = ["\(added) added"]
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts
    }

    /// Fits the user's own images in the output folder to the screen (originals moved to "<folder> Originals").
    private func fitLocalImages() async -> [String] {
        let options = pipelineOptions
        let folder = outputFolder
        let files = await Task.detached { LocalFitter.candidates(in: folder, target: options.target) }.value
            .filter { !skippedLocalFiles.contains($0.lastPathComponent) }
        guard !files.isEmpty else { return [] }
        var fitted = 0, failed = 0
        for (index, file) in files.enumerated() {
            activity = .fitting(done: index, total: files.count)
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try await LocalFitter.fit(file, options: options)
                }.value
                switch outcome {
                case .fitted: fitted += 1
                case .skipped(let note):
                    skippedLocalFiles.insert(file.lastPathComponent)
                    log.info("left \(file.lastPathComponent, privacy: .public) as is: \(note, privacy: .public)")
                }
            } catch {
                failed += 1
                skippedLocalFiles.insert(file.lastPathComponent)
                log.error("fitting \(file.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            reloadWallpapers()
        }
        activity = .idle
        var parts: [String] = []
        if fitted > 0 { parts.append("\(fitted) of your images fitted") }
        if failed > 0 { parts.append("\(failed) couldn't be fitted") }
        return parts
    }

    /// Redo every wallpaper from its original (after changing the model or screen).
    /// Pins are downloaded again; own images are restored from the Originals folder and fitted again.
    func reprocessEverything() async {
        guard !isBusy else { return }
        // Only wallpapers still in the folder: anything the user trashed stays gone.
        let fm = FileManager.default
        let donePins = library.records.values.filter { record in
            guard record.status == .done, let output = record.output else { return false }
            return fm.fileExists(atPath: outputFolder.appending(path: output).path(percentEncoded: false))
        }.map(\.pin.id)
        try? library.remove(donePins)

        if fitOwnImages {
            let originals = LocalFitter.originalsFolder(for: outputFolder)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: originals, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for original in files {
                let fitted = outputFolder.appending(path: original.deletingPathExtension().lastPathComponent + ".jpg")
                guard fm.fileExists(atPath: fitted.path(percentEncoded: false)) else { continue }
                try? fm.trashItem(at: fitted, resultingItemURL: nil)
                try? fm.moveItem(at: original, to: outputFolder.appending(path: original.lastPathComponent))
            }
            skippedLocalFiles = []
        }
        lastSync = nil
        await sync()
    }

    // MARK: Wallpapers

    func reloadWallpapers() {
        guard !isDemo else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: outputFolder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let byOutput = Dictionary(library.records.values.compactMap { r in r.output.map { ($0, r) } },
                                  uniquingKeysWith: { a, _ in a })
        wallpapers = files
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .map { url in
                let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return Wallpaper(url: url, modified: date, record: byOutput[url.lastPathComponent])
            }
            .sorted { $0.modified > $1.modified }
        skippedPins = library.recent.filter { $0.status == .skippedShape || $0.status == .skippedNotImage }
    }

    /// Moves a wallpaper to the Trash. Its pin stays "seen", so it isn't downloaded again.
    func trash(_ wallpaper: Wallpaper) {
        if wallpaper.url == pinnedWallpaper { resumeRotation() }
        if isDemo {
            wallpapers.removeAll { $0.url == wallpaper.url }
            return
        }
        NSWorkspace.shared.recycle([wallpaper.url]) { [weak self] _, _ in
            Task { @MainActor in self?.reloadWallpapers() }
        }
    }

    /// Shows one wallpaper right now. macOS then stops rotating on the current desktop (Space)
    /// until `resumeRotation()`.
    func setAsDesktop(_ wallpaper: Wallpaper) {
        guard !isDemo else { pinnedWallpaper = wallpaper.url; return }
        do {
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(wallpaper.url, for: screen, options: [:])
            }
            pinnedWallpaper = wallpaper.url
        } catch {
            errorMessage = "Couldn't set the wallpaper: \(error.localizedDescription)"
        }
    }

    func resumeRotation() {
        useFolderAsDesktopWallpaper()
    }

    /// Point macOS's wallpaper rotation at the output folder on every screen (current Space).
    func useFolderAsDesktopWallpaper() {
        pinnedWallpaper = nil
        guard !isDemo else { return }
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        do {
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(outputFolder, for: screen, options: [:])
            }
        } catch {
            errorMessage = "Couldn't set the wallpaper folder: \(error.localizedDescription)"
        }
    }

    func openOutputFolder() {
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputFolder)
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputFolder
        panel.prompt = "Use Folder"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url }
    }

    // MARK: Persistence

    private func store<T: Encodable>(_ value: T?, key: String) {
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    // MARK: Demo (screenshots, UI checks)

    func loadDemo(account: Account, boards: [Board], board: Board?, wallpapers: [Wallpaper],
                  skipped: [PinRecord], activity: Activity, lastResult: String?, pendingImport: [Pin]? = nil) {
        self.account = account
        self.boards = boards
        self.board = board
        self.wallpapers = wallpapers
        self.skippedPins = skipped
        self.activity = activity
        self.lastResult = lastResult
        self.lastSync = .now.addingTimeInterval(-120)
        self.pendingImport = pendingImport
    }
}
