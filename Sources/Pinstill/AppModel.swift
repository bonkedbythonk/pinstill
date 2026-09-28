import AppKit
import Foundation
import Observation
import os
import PinstillCore
import CryptoKit
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
    private(set) var errorMessage: String? {
        didSet { errorLink = nil }
    }
    /// Where to go about `errorMessage`, when there's somewhere useful (the issue tracker).
    private(set) var errorLink: URL?
    /// Set when a freshly linked board already has pins: ask before importing them all.
    private(set) var pendingImport: [Pin]?

    /// Board still waiting for that answer. Persisted: quitting before answering used to
    /// import the whole board on the next launch without asking.
    private var awaitingImportDecision: String? {
        didSet { defaults.set(awaitingImportDecision, forKey: "awaitingImportDecision") }
    }
    private(set) var upscaler: Upscaler?
    /// A newer release on GitHub, if the last check found one.
    private(set) var availableUpdate: UpdateCheck.Release?
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

    /// Desktops (Spaces) showing one image from the folder instead of rotating through it.
    private(set) var stuckDesktops = 0

    /// A single wallpaper the user set directly; rotation is paused on that desktop until resumed.
    var pinnedWallpaper: URL? {
        didSet { defaults.set(pinnedWallpaper?.path(percentEncoded: false), forKey: "pinnedWallpaper") }
    }

    /// Who rotates the wallpapers: macOS (works with Pinstill closed) or Pinstill (more control,
    /// has to stay open).
    var rotationMode: RotationMode {
        didSet {
            guard rotationMode != oldValue else { return }
            store(rotationMode, key: "rotationMode")
            rotationModeChanged()
        }
    }

    /// macOS mode: how often macOS switches. nil until read from macOS or chosen.
    var macInterval: ShuffleInterval? {
        didSet { store(macInterval, key: "macInterval") }
    }

    var macRandomly: Bool? {
        didSet { defaults.set(macRandomly, forKey: "macRandomly") }
    }

    /// Pinstill mode: seconds between wallpapers, and in which order.
    var pinstillInterval: TimeInterval {
        didSet {
            defaults.set(pinstillInterval, forKey: "pinstillInterval")
            scheduleRotation()
        }
    }

    var pinstillOrder: RotationOrder {
        didSet { store(pinstillOrder, key: "pinstillOrder") }
    }

    /// Pinstill mode: what's showing and when it changes.
    private(set) var currentWallpaper: URL?
    private(set) var nextChange: Date?
    @ObservationIgnored private var rotationTimer: Timer?
    @ObservationIgnored private var spaceObserver: NSObjectProtocol?

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
    private let log = Logger(subsystem: "Pinstill", category: "sync")
    /// Upper bound on pages fetched per sync (25 pins each).
    private let maxPages = 10

    nonisolated static let supportFolder = URL.applicationSupportDirectory.appending(path: "Pinstill")
    static let defaultOutputFolder = URL.picturesDirectory.appending(path: "Pinstill", directoryHint: .isDirectory)

    /// A separate Pinstill for testing first run: own settings, library, Pinterest login and
    /// wallpaper folder. `Pinstill --profile <name> [--no-upscayl]`; not shown in the UI.
    struct Profile {
        let name: String
        let hideUpscayl: Bool

        var defaults: UserDefaults { UserDefaults(suiteName: "io.github.bonkedbythonk.pinstill.profile.\(name)")! }
        var folder: URL { AppModel.supportFolder.appending(path: "Profiles/\(name)") }
    }

    let profile: Profile?

    convenience init(profile: Profile) {
        self.init(defaults: profile.defaults, libraryFile: profile.folder.appending(path: "library.json"),
                  session: PinterestSession(dataStore: .init(forIdentifier: profile.dataStoreID)),
                  profile: profile)
    }

    init(defaults: UserDefaults = .standard, libraryFile: URL = AppModel.supportFolder.appending(path: "library.json"),
         demo: Bool = false, session: PinterestSession = PinterestSession(), profile: Profile? = nil) {
        self.defaults = defaults
        isDemo = demo
        self.session = session
        self.profile = profile
        library = Library(file: libraryFile)
        outputFolder = defaults.string(forKey: "outputFolder").map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? (profile.map { $0.folder.appending(path: "Wallpapers", directoryHint: .isDirectory) } ?? Self.defaultOutputFolder)
        board = Self.load(Board.self, key: "board", from: defaults)
        fitOwnImages = defaults.object(forKey: "fitOwnImages") as? Bool ?? false
        upscaleModel = Self.load(UpscaleModel.self, key: "upscaleModel", from: defaults) ?? .automatic
        hasCompletedSetup = defaults.bool(forKey: "hasCompletedSetup")
        pinnedWallpaper = defaults.string(forKey: "pinnedWallpaper").map { URL(filePath: $0) }
        awaitingImportDecision = defaults.string(forKey: "awaitingImportDecision")
        rotationMode = Self.load(RotationMode.self, key: "rotationMode", from: defaults) ?? .macOS
        macInterval = Self.load(ShuffleInterval.self, key: "macInterval", from: defaults)
        macRandomly = defaults.object(forKey: "macRandomly") as? Bool
        pinstillInterval = defaults.object(forKey: "pinstillInterval") as? Double ?? 15 * 60
        pinstillOrder = Self.load(RotationOrder.self, key: "pinstillOrder", from: defaults) ?? .random
        upscaler = profile?.hideUpscayl == true ? nil : Upscaler.locate()
        target = Screens.largestPixelSize()
        if !demo {
            session.onNavigationFinished = { [weak self] url in
                Task { await self?.navigationFinished(url) }
            }
            reloadWallpapers()
            if macInterval == nil { loadMacRotation() }
            if rotationMode == .pinstill { startRotation() }
        }
    }

    var isBusy: Bool { activity != .idle }
    var installedModels: [String] { upscaler?.installedModels ?? [] }

    // MARK: Lifecycle

    /// Launch and menu open: check login, then sync if a board is linked.
    func refresh() async {
        guard !isDemo else { return }
        Task { await checkForUpdate() }
        log.info("refresh requested (busy: \(self.isBusy))")
        target = Screens.largestPixelSize()
        reloadWallpapers()
        await checkStuckDesktops()
        guard !isBusy else { return }
        if case .loggedIn = account, let lastSync, Date.now.timeIntervalSince(lastSync) < 20 { return }
        await checkAccount()
        if case .loggedIn = account, board != nil, pendingImport == nil, hasCompletedSetup {
            await sync()
        } else if fitOwnImages, hasCompletedSetup {
            // Own images don't need Pinterest: fit them even while logged out, or a redo that
            // got interrupted would leave originals sitting in the folder until the next login.
            activity = .checking
            let summary = await fitLocalImages()
            activity = .idle
            if !summary.isEmpty { lastResult = summary.joined(separator: " · ") }
            reloadWallpapers()
        }
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
            report(error)
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
            report(error)
        }
    }

    func logOut() async {
        await session.logOut()
        account = .loggedOut
        boards = []
    }

    func refreshUpscaler() {
        upscaler = profile?.hideUpscayl == true ? nil : Upscaler.locate()
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
        awaitingImportDecision = board.id
        await sync(linking: true)
    }

    /// Brings back the "import existing pins?" question for a board that never got an answer.
    func resumePendingImport() async {
        guard let board, awaitingImportDecision == board.id, pendingImport == nil else { return }
        await sync(linking: true)
    }

    func importExisting(_ include: Bool) async {
        guard let pins = pendingImport else { return }
        pendingImport = nil
        awaitingImportDecision = nil
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
        let linking = linking || awaitingImportDecision == board.id
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
            if linking { awaitingImportDecision = nil } // empty board: nothing to decide
            var summary = fresh.isEmpty ? [] : await process(fresh)
            if fitOwnImages { summary += await fitLocalImages() }
            lastResult = summary.isEmpty ? "Up to date" : summary.joined(separator: " · ")
            activity = .idle
        } catch SessionError.http(let status, _) where status == 401 || status == 403 {
            // Also what Pinterest answers when its request format changes, so tell the two
            // apart by whether the account check itself still works.
            activity = .idle
            await checkAccount()
            if case .loggedIn = account { report(error: SessionError.http(status, resource: "board")) }
        } catch {
            report(error)
            activity = .idle
        }
        reloadWallpapers()
    }

    private var pipelineOptions: PipelineOptions {
        var options = PipelineOptions(
            target: target,
            outputFolder: outputFolder,
            workFolder: URL.cachesDirectory.appending(path: "Pinstill/work"),
            upscaler: upscaler)
        options.model = upscaleModel
        options.existingOutputs = redoOutputs
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
        let redo = library.records.values.filter { record in
            guard record.status == .done, let output = record.output else { return false }
            return fm.fileExists(atPath: outputFolder.appending(path: output).path(percentEncoded: false))
        }
        redoOutputs = Dictionary(uniqueKeysWithValues: redo.compactMap { r in r.output.map { (r.pin.id, $0) } })
        try? library.remove(redo.map(\.pin.id))

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
        redoOutputs = [:]
    }

    /// Set while `reprocessEverything` runs: which file each redone pin overwrites.
    @ObservationIgnored private var redoOutputs: [String: String] = [:]

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
        if rotationMode == .macOS, wallpaper.url == pinnedWallpaper { resumeRotation() }
        if rotationMode == .pinstill, wallpaper.url == currentWallpaper { nextWallpaper() }
        if isDemo {
            wallpapers.removeAll { $0.url == wallpaper.url }
            return
        }
        NSWorkspace.shared.recycle([wallpaper.url]) { [weak self] _, _ in
            Task { @MainActor in self?.reloadWallpapers() }
        }
    }

    // MARK: Rotation

    enum RotationMode: String, Codable { case macOS, pinstill }
    enum RotationOrder: String, Codable, CaseIterable { case random, newestFirst }

    /// The wallpaper showing on the desktop right now, when Pinstill knows it.
    var desktopWallpaper: URL? { rotationMode == .pinstill ? currentWallpaper : pinnedWallpaper }

    /// Shows one wallpaper right now. In macOS mode that pauses macOS's rotation on the current
    /// desktop until `resumeRotation()`; in Pinstill mode rotation carries on from it.
    func setAsDesktop(_ wallpaper: Wallpaper) {
        if rotationMode == .pinstill {
            show(wallpaper.url)
            scheduleRotation()
            return
        }
        guard show(wallpaper.url) else { return }
        pinnedWallpaper = wallpaper.url
        Task {
            try? await Task.sleep(for: .seconds(1.5)) // WallpaperAgent writes its store asynchronously
            await checkStuckDesktops()
        }
    }

    /// Puts every desktop showing a single Pinstill wallpaper back on the folder's rotation,
    /// with the chosen interval. Setting the folder through NSWorkspace would only reach the
    /// current desktop and reset the interval to 30 minutes.
    func resumeRotation() {
        pinnedWallpaper = nil
        guard !isDemo else { stuckDesktops = 0; return }
        let folder = outputFolder, interval = macInterval, randomly = macRandomly
        Task {
            let changed = await Task.detached { () -> Int? in
                guard let changed = try? MacRotation.rotateAll(folder: folder, interval: interval, randomly: randomly) else { return nil }
                if changed > 0 { MacRotation.restartAgent() }
                return changed
            }.value
            if changed == nil { errorMessage = "Couldn't change macOS's wallpaper settings." }
            await checkStuckDesktops()
        }
    }

    func checkStuckDesktops() async {
        guard !isDemo, rotationMode == .macOS else { stuckDesktops = 0; return }
        let folder = outputFolder
        stuckDesktops = await Task.detached { MacRotation.stuckDesktops(in: folder) }.value
    }

    /// Point macOS's wallpaper rotation at the output folder on every screen (current Space),
    /// then put back the chosen interval, which setting a folder resets to 30 minutes.
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
            return
        }
        guard macInterval != nil || macRandomly != nil else { return }
        Task {
            // WallpaperAgent writes the folder to its store asynchronously; patching before
            // that lands gets overwritten.
            try? await Task.sleep(for: .seconds(1.5))
            await applyMacRotation()
        }
    }

    /// Writes `macInterval` / `macRandomly` into macOS's wallpaper settings for this folder.
    func applyMacRotation() async {
        guard !isDemo else { return }
        let folder = outputFolder, interval = macInterval, randomly = macRandomly
        let changed = await Task.detached { () -> Int? in
            guard let changed = try? MacRotation.apply(folder: folder, interval: interval, randomly: randomly) else { return nil }
            if changed > 0 { MacRotation.restartAgent() }
            return changed
        }.value
        switch changed {
        case nil: errorMessage = "Couldn't change macOS's wallpaper settings."
        case 0?: errorMessage = "No desktop rotates through this folder yet. Use “Make it my wallpaper” first."
        default: errorMessage = nil
        }
    }

    /// What macOS currently has for this folder, to show in Settings.
    func loadMacRotation() {
        guard !isDemo, let current = MacRotation.current(for: outputFolder) else { return }
        if let interval = current.interval { macInterval = interval }
        macRandomly = current.randomly ?? true
    }

    /// Pinstill mode: next wallpaper now, and restart the countdown.
    func nextWallpaper() {
        guard let next = pickNext() else { return }
        show(next)
        scheduleRotation()
    }

    private func startRotation() {
        guard !isDemo else { return }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // setDesktopImageURL only reaches the Space that's active, so each desktop gets
            // the current wallpaper when you switch to it.
            MainActor.assumeIsolated {
                guard let self, let current = self.currentWallpaper else { return }
                self.show(current)
            }
        }
        nextWallpaper()
    }

    private func stopRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        nextChange = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
    }

    private func scheduleRotation() {
        rotationTimer?.invalidate()
        guard rotationMode == .pinstill else { return }
        nextChange = .now.addingTimeInterval(pinstillInterval)
        rotationTimer = Timer.scheduledTimer(withTimeInterval: pinstillInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.nextWallpaper() }
        }
    }

    private func pickNext() -> URL? {
        let pool = wallpapers.map(\.url)
        guard !pool.isEmpty else { return nil }
        switch pinstillOrder {
        case .random:
            return pool.filter { $0 != currentWallpaper }.randomElement() ?? pool.first
        case .newestFirst:
            guard let current = currentWallpaper, let index = pool.firstIndex(of: current) else { return pool.first }
            return pool[(index + 1) % pool.count]
        }
    }

    @discardableResult
    private func show(_ url: URL) -> Bool {
        if isDemo { currentWallpaper = url; return true }
        do {
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            }
            if rotationMode == .pinstill { currentWallpaper = url }
            return true
        } catch {
            errorMessage = "Couldn't set the wallpaper: \(error.localizedDescription)"
            return false
        }
    }

    private func rotationModeChanged() {
        switch rotationMode {
        case .pinstill:
            pinnedWallpaper = nil
            startRotation()
        case .macOS:
            stopRotation()
            currentWallpaper = nil
            useFolderAsDesktopWallpaper()
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

    // MARK: Updates

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// At most once a day unless `force`d (the button in About).
    func checkForUpdate(force: Bool = false) async {
        guard !isDemo else { return }
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard force || Date.now.timeIntervalSince(last) > 24 * 3600 else { return }
        defaults.set(Date.now, forKey: "lastUpdateCheck")
        guard let latest = try? await UpdateCheck.latest() else { return }
        availableUpdate = UpdateCheck.isNewer(latest.version, than: Self.currentVersion) ? latest : nil
    }

    // MARK: Errors

    static let issuesURL = URL(string: "https://github.com/bonkedbythonk/pinstill/issues")!

    /// Turns an error into something a person can act on.
    private func report(_ error: Error) { report(error: error) }

    private func report(error: Error) {
        log.error("\(String(describing: error), privacy: .public)")
        switch error {
        case let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                          .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code):
            errorMessage = "Can't reach Pinterest. Check your internet connection and try again."
        case is SessionError, is PinterestAPIError, is DecodingError:
            errorMessage = "Pinterest changed something on their end, so Pinstill can't read your board right now. An update to Pinstill will fix it."
            errorLink = Self.issuesURL
        default:
            if (error as NSError).domain == "WKErrorDomain" {
                // fetch() inside the page failing: offline, or Pinterest refusing the request.
                errorMessage = "Couldn't get your board from Pinterest. If you're online, Pinterest may have changed something."
                errorLink = Self.issuesURL
            } else {
                errorMessage = "Something went wrong: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Persistence

    private func store<T: Encodable>(_ value: T?, key: String) {
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    // MARK: Demo (screenshots, UI checks)

    func loadDemoStuckDesktops(_ count: Int) { stuckDesktops = count }

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

extension AppModel.Profile {
    /// Stable per profile, so its Pinterest login survives relaunches.
    var dataStoreID: UUID {
        let bytes = Array(SHA256.hash(data: Data(name.utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
