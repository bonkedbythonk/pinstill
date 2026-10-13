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
    /// The board whose folder it's in.
    var linkID: String?

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
    /// Wallpapers of every board, newest first. Rotation uses all of them.
    private(set) var allWallpapers: [Wallpaper] = []
    private var leftOutEntries: [(board: String?, record: PinRecord)] = []

    /// Which board the wall shows when there are several; nil = all of them.
    var shownBoardID: String? {
        didSet { defaults.set(shownBoardID, forKey: "shownBoard") }
    }
    /// The board the wall is limited to, if it's one of several.
    var shownLink: BoardLink? {
        links.count > 1 ? links.first { $0.id == shownBoardID } : nil
    }
    /// What the wall shows: the shown board's wallpapers, or everyone's.
    var wallpapers: [Wallpaper] {
        guard let shownLink else { return allWallpapers }
        return allWallpapers.filter { $0.linkID == shownLink.id }
    }
    /// Pins that were seen but didn't become a wallpaper, newest first (a pin on two boards once).
    var leftOutPins: [PinRecord] {
        var seen = Set<String>()
        return leftOutEntries
            .filter { shownLink == nil || $0.board == shownLink?.id }
            .map(\.record)
            .sorted { $0.processedAt > $1.processedAt }
            .filter { seen.insert($0.pin.id).inserted }
    }
    var skippedPins: [PinRecord] {
        leftOutPins.filter { $0.status == .skippedShape || $0.status == .skippedNotImage }
    }

    var tallSkippedPins: [PinRecord] { leftOutPins.filter { $0.status == .skippedShape } }

    /// Why the wall is empty although the board has pins, one sentence per reason.
    var leftOutReasons: [String] {
        func count(_ status: PinStatus) -> Int { leftOutPins.count { $0.status == status } }
        func pins(_ n: Int) -> String { n == 1 ? "1 pin" : "\(n) pins" }
        var reasons: [String] = []
        let shape = count(.skippedShape), video = count(.skippedNotImage)
        let existing = count(.skippedExisting), failed = count(.failed)
        if shape > 0 {
            reasons.append("\(pins(shape)) skipped: too tall to fill the screen without cropping most of it away. Wide pins work best.")
        }
        if video > 0 { reasons.append("\(pins(video)) skipped: a video or idea pin, not an image.") }
        if existing > 0 {
            reasons.append("\(pins(existing)) left out: already on the board when you linked it. Pins you save from now on are added.")
        }
        if failed > 0, let note = leftOutPins.first(where: { $0.status == .failed })?.note {
            reasons.append("\(pins(failed)) failed: \(note)")
        }
        return reasons
    }
    private(set) var lastSync: Date? {
        didSet { defaults.set(lastSync, forKey: "lastSync") }
    }
    private(set) var lastResult: String?
    private(set) var errorMessage: String? {
        didSet { errorLink = nil }
    }
    /// Where to go about `errorMessage`, when there's somewhere useful (the issue tracker).
    private(set) var errorLink: URL?
    /// Set when a freshly linked board already has pins: ask before importing them all.
    private(set) var pendingImport: [Pin]?
    private(set) var pendingImportLink: BoardLink?

    /// Board still waiting for that answer. Persisted: quitting before answering used to
    /// import the whole board on the next launch without asking.
    private var awaitingImportDecision: String? {
        didSet { defaults.set(awaitingImportDecision, forKey: "awaitingImportDecision") }
    }
    private(set) var upscaler: Upscaler?
    /// A newer release on GitHub, if the last check found one.
    private(set) var availableUpdate: UpdateCheck.Release?
    private(set) var target: PixelSize
    /// What size the wallpapers were last made for, to notice when a bigger display shows up.
    private var renderedTarget: PixelSize?

    /// A display with more pixels than the wallpapers were made for is connected.
    var displayOutgrewWallpapers: Bool {
        guard let renderedTarget, !allWallpapers.isEmpty else { return false }
        return target.hasMorePixels(than: renderedTarget)
    }

    // MARK: Settings

    /// The boards feeding wallpapers, each with its own folder and its own history of seen pins.
    private(set) var links: [BoardLink] {
        didSet { store(links, key: "links") }
    }
    var hasBoards: Bool { !links.isEmpty }
    /// The first board; what single-board screens talk about.
    var board: Board? { links.first?.board }
    /// "Wallpapers" for one board, "2 boards" for more.
    var boardsTitle: String { links.count == 1 ? links[0].board.name : "\(links.count) boards" }

    /// Where wallpapers go before a board is linked (setup), and the first board's folder after.
    private var startingFolder: URL
    var outputFolder: URL {
        get { links.first?.folder ?? startingFolder }
        set {
            startingFolder = newValue
            defaults.set(newValue.path(percentEncoded: false), forKey: "outputFolder")
            if !links.isEmpty { links[0].setFolder(newValue) }
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

    /// Check the board after the Mac wakes from sleep, at most once an hour. Off by default:
    /// otherwise Pinstill only asks Pinterest when it's opened or its menu is.
    var syncOnWake: Bool {
        didSet { defaults.set(syncOnWake, forKey: "syncOnWake") }
    }

    /// Say so when a sync after waking added wallpapers.
    var notifyOnNew: Bool {
        didSet {
            defaults.set(notifyOnNew, forKey: "notifyOnNew")
            guard notifyOnNew, !oldValue, !isDemo else { return }
            Task {
                if await !Notifier.requestAuthorization() { notifyOnNew = false }
            }
        }
    }

    /// Control-Option-Command-Right arrow for the next wallpaper, -Delete to remove the current
    /// one. Only does anything while Pinstill is the one rotating.
    var hotKeysEnabled: Bool {
        didSet {
            defaults.set(hotKeysEnabled, forKey: "hotKeysEnabled")
            applyHotKeys()
        }
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
    @ObservationIgnored var popoverIsShown: () -> Bool = { false }
    @ObservationIgnored var presentCropEditor: (PinRecord, String?) -> Void = { _, _ in }

    // MARK: Internals

    let session: PinterestSession
    let isDemo: Bool
    private var libraries: [String: Library] = [:]
    private let libraryFolder: URL
    /// The board and library file of a setup from before several boards were possible.
    private let legacyBoardID: String?
    private let legacyLibraryName: String
    /// Own images left alone this session (wrong shape / failed), so they aren't retried every sync.
    @ObservationIgnored private var skippedLocalFiles: Set<String> = []
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "Pinstill", category: "sync")
    /// Set while a sync nobody asked for runs: connection errors stay out of the popover.
    @ObservationIgnored private var quiet = false
    @ObservationIgnored private var addedThisRun = 0
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
        let libraryFolder = libraryFile.deletingLastPathComponent()
        self.libraryFolder = libraryFolder
        legacyBoardID = Self.load(Board.self, key: "board", from: defaults)?.id
        legacyLibraryName = libraryFile.lastPathComponent
        let folder = defaults.string(forKey: "outputFolder").map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? (profile.map { $0.folder.appending(path: "Wallpapers", directoryHint: .isDirectory) } ?? Self.defaultOutputFolder)
        startingFolder = folder
        // Before several boards were possible: one board, one folder, everything in library.json.
        var linked = Self.load([BoardLink].self, key: "links", from: defaults)
        if linked == nil {
            linked = BoardLinks.migrate(board: Self.load(Board.self, key: "board", from: defaults), folder: folder,
                                        legacyLibraryName: libraryFile.lastPathComponent)
            defaults.set(try? JSONEncoder().encode(linked), forKey: "links")
        }
        links = linked ?? []
        shownBoardID = defaults.string(forKey: "shownBoard")
        fitOwnImages = defaults.object(forKey: "fitOwnImages") as? Bool ?? false
        upscaleModel = Self.load(UpscaleModel.self, key: "upscaleModel", from: defaults) ?? .automatic
        syncOnWake = defaults.bool(forKey: "syncOnWake")
        notifyOnNew = defaults.bool(forKey: "notifyOnNew")
        hotKeysEnabled = defaults.bool(forKey: "hotKeysEnabled")
        lastSync = defaults.object(forKey: "lastSync") as? Date
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
        renderedTarget = Self.load(PixelSize.self, key: "renderedTarget", from: defaults)
        for link in links { libraries[link.id] = Library(file: libraryFolder.appending(path: link.libraryName)) }
        if !demo {
            if renderedTarget == nil { renderedTarget = target; store(target, key: "renderedTarget") }
            observeSystemEvents()
            applyHotKeys()
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
        if case .loggedIn = account, hasBoards, pendingImport == nil, hasCompletedSetup {
            await sync()
        } else if fitOwnImages, hasCompletedSetup {
            // Own images don't need Pinterest: fit them even while logged out, or a redo that
            // got interrupted would leave originals sitting in the folder until the next login.
            activity = .checking
            var summary: [String] = []
            for folder in links.isEmpty ? [outputFolder] : links.map(\.folder) {
                summary += await fitLocalImages(in: folder)
            }
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
            for index in links.indices {
                if let fresh = boards.first(where: { $0.id == links[index].id }), fresh != links[index].board {
                    links[index].board = fresh
                }
            }
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

    enum UpscaylInstall: Equatable {
        case idle
        case downloading(Double)
        case installing
        case failed(String)
    }

    private(set) var upscaylInstall: UpscaylInstall = .idle

    /// Downloads Upscayl's official DMG and puts the app in Applications.
    func installUpscayl() async {
        switch upscaylInstall {
        case .downloading, .installing: return
        case .idle, .failed: break
        }
        upscaylInstall = .downloading(0)
        do {
            let app = try await UpscaylInstaller.install { [weak self] step in
                Task { @MainActor in
                    switch step {
                    case .downloading(let fraction): self?.upscaylInstall = .downloading(fraction)
                    case .installing: self?.upscaylInstall = .installing
                    }
                }
            }
            // Launch Services can take a moment to learn about a new app; use the path we know.
            upscaler = Upscaler.at(app) ?? Upscaler.locate()
            upscaylInstall = .idle
        } catch let error as UpscaylInstaller.InstallError {
            upscaylInstall = .failed(error.description)
        } catch {
            upscaylInstall = .failed("The download didn't finish. Check your connection and try again.")
        }
    }

    /// Login page navigations: once Pinterest leaves the login page, check whether we're in.
    private func navigationFinished(_ url: URL?) async {
        guard account == .loggedOut, let path = url?.path(percentEncoded: false), !path.contains("login") else { return }
        await checkAccount()
    }

    // MARK: Boards

    /// Links a board with a folder of its own. When it already has pins, `pendingImport` asks
    /// whether to import them. Waits while an earlier board's question is still open.
    func choose(_ board: Board) async {
        guard !isDemo, !isBusy, pendingImport == nil, !links.contains(where: { $0.id == board.id }) else { return }
        let folder = links.isEmpty ? outputFolder : BoardLinks.defaultFolder(for: board, base: outputFolder, existing: links)
        let link = BoardLink(board: board, folder: folder,
                             libraryName: BoardLinks.libraryName(for: board.id, legacyBoardID: legacyBoardID,
                                                                 legacyName: legacyLibraryName))
        libraries[link.id] = Library(file: libraryFolder.appending(path: link.libraryName))
        links.append(link)
        awaitingImportDecision = board.id
        finish(single: await syncBoard(link, linking: true))
    }

    /// Stops following a board. Its wallpapers stay in their folder and its history is kept,
    /// so linking it again later doesn't start over.
    func unlink(_ boardID: String) {
        links.removeAll { $0.id == boardID }
        libraries[boardID] = nil
        if pendingImportLink?.id == boardID { pendingImport = nil; pendingImportLink = nil }
        if awaitingImportDecision == boardID { awaitingImportDecision = nil }
        reloadWallpapers()
    }

    /// Brings back the "import existing pins?" question for a board that never got an answer.
    func resumePendingImport() async {
        guard !isBusy, pendingImport == nil, let id = awaitingImportDecision,
              let link = links.first(where: { $0.id == id }) else { return }
        finish(single: await syncBoard(link, linking: true))
    }

    private func finish(single parts: [String]?) {
        if let parts { lastResult = parts.isEmpty ? "Up to date" : parts.joined(separator: " · ") }
        reloadWallpapers()
    }

    func importExisting(_ include: Bool) async {
        guard let pins = pendingImport, let link = pendingImportLink else { return }
        pendingImport = nil
        pendingImportLink = nil
        awaitingImportDecision = nil
        if include {
            lastResult = await process(pins, in: link).parts.joined(separator: " · ")
        } else {
            let records = pins.map { PinRecord(pin: $0, status: .skippedExisting, note: "Was on the board before linking") }
            try? libraries[link.id]?.save(records)
            lastResult = "Only pins added from now on will be imported"
        }
        reloadWallpapers()
    }

    // MARK: Sync

    /// Checks every linked board, one after the other; stops at the first problem.
    func sync() async {
        guard !isDemo, !isBusy, hasBoards else { return }
        errorMessage = nil
        var results: [(board: String, parts: [String])] = []
        var failures: [(board: String, message: String, link: URL?)] = []
        for link in links {
            if let parts = await syncBoard(link, linking: awaitingImportDecision == link.id) {
                results.append((link.board.name, parts))
                continue
            }
            if let message = errorMessage { failures.append((link.board.name, message, errorLink)) }
            // A board that can't be read (deleted, say) shouldn't hold back the others, but a
            // question waiting for an answer or a lost login stops everything.
            guard pendingImport == nil, case .loggedIn = account else { break }
            errorMessage = nil
        }
        if let first = failures.first {
            errorMessage = links.count == 1
                ? first.message
                : failures.map { "\($0.board): \($0.message)" }.joined(separator: "\n")
            errorLink = first.link
        }
        if pendingImport == nil, !results.isEmpty {
            let changed = results.filter { !$0.parts.isEmpty }
            if changed.isEmpty {
                lastResult = "Up to date"
            } else if links.count == 1 {
                lastResult = changed[0].parts.joined(separator: " · ")
            } else {
                lastResult = changed.map { "\($0.board): \($0.parts.joined(separator: ", "))" }.joined(separator: " · ")
            }
        }
        reloadWallpapers()
    }

    /// One board: read its pins, make wallpapers from the new ones. nil when it stopped early (an
    /// error, or the import question).
    private func syncBoard(_ link: BoardLink, linking: Bool) async -> [String]? {
        activity = .checking
        defer { if activity == .checking { activity = .idle } }

        do {
            var pins: [Pin] = [], unusable: [Pin] = []
            var bookmark: String?
            for _ in 0..<maxPages {
                let page = try await session.boardPage(boardID: link.id, bookmark: bookmark)
                pins += page.pins
                unusable += page.unusable
                bookmark = page.bookmark
                if bookmark == nil { break }
            }
            lastSync = .now
            guard var library = libraries[link.id] else { return nil }

            let newUnusable = unusable.filter { !library.isSeen($0.id) }
            try library.save(newUnusable.map {
                PinRecord(pin: $0, status: .skippedNotImage, note: "Video or idea pin without an image")
            })
            libraries[link.id] = library

            var seenIDs = Set<String>()
            let fresh = pins.filter { !library.isSeen($0.id) && seenIDs.insert($0.id).inserted }
            log.info("board \(link.board.name, privacy: .public): \(pins.count) pins, \(fresh.count) new")

            if linking, !fresh.isEmpty {
                pendingImport = fresh
                pendingImportLink = link
                activity = .idle
                return nil
            }
            if linking { awaitingImportDecision = nil } // empty board: nothing to decide
            var summary = fresh.isEmpty ? [] : await process(fresh, in: link).parts
            if fitOwnImages { summary += await fitLocalImages(in: link.folder) }
            activity = .idle
            return summary
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
        return nil
    }

    private func pipelineOptions(folder: URL, board: String? = nil) -> PipelineOptions {
        var options = PipelineOptions(
            target: target,
            outputFolder: folder,
            workFolder: URL.cachesDirectory.appending(path: "Pinstill/work"),
            upscaler: upscaler)
        options.model = upscaleModel
        options.existingOutputs = board.flatMap { redoState[$0]?.outputs } ?? [:]
        return options
    }

    struct Counts {
        var added = 0, skipped = 0, failed = 0

        var parts: [String] {
            var parts = ["\(added) added"]
            if skipped > 0 { parts.append("\(skipped) skipped") }
            if failed > 0 { parts.append("\(failed) failed") }
            return parts
        }

        static func += (a: inout Counts, b: Counts) {
            a.added += b.added; a.skipped += b.skipped; a.failed += b.failed
        }
    }

    /// Processes a board's pins into its folder.
    private func process(_ pins: [Pin], in link: BoardLink, minKeep: Double? = nil) async -> Counts {
        var adjusted = pipelineOptions(folder: link.folder, board: link.id)
        if let minKeep { adjusted.minKeep = minKeep }
        let standard = adjusted
        var lenientOptions = standard
        lenientOptions.minKeep = 0
        let lenient = lenientOptions
        let redo = redoState[link.id]
        var counts = Counts()
        for (index, pin) in pins.enumerated() {
            activity = .processing(done: index, total: pins.count)
            let record: PinRecord
            let options = redo?.croppedAnyway.contains(pin.id) == true ? lenient : standard
            let crop = redo?.crops[pin.id]
            do {
                // Vision, Core Image and upscayl-bin block: keep them off the main actor.
                record = try await Task.detached(priority: .userInitiated) {
                    try await Pipeline.process(pin, options: options, crop: crop).record
                }.value
            } catch {
                record = PinRecord(pin: pin, status: .failed, note: "\(error)")
            }
            switch record.status {
            case .done: counts.added += 1; addedThisRun += 1
            case .failed: counts.failed += 1
            default: counts.skipped += 1
            }
            try? libraries[link.id]?.save(record)
            reloadWallpapers()
        }
        activity = .idle
        return counts
    }

    /// Fits the user's own images in `folder` to the screen (originals moved to "<folder> Originals").
    private func fitLocalImages(in folder: URL) async -> [String] {
        let options = pipelineOptions(folder: folder)
        let files = await Task.detached { LocalFitter.candidates(in: folder, target: options.target) }.value
            .filter { !skippedLocalFiles.contains($0.path(percentEncoded: false)) }
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
                    skippedLocalFiles.insert(file.path(percentEncoded: false))
                    log.info("left \(file.lastPathComponent, privacy: .public) as is: \(note, privacy: .public)")
                }
            } catch {
                failed += 1
                skippedLocalFiles.insert(file.path(percentEncoded: false))
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
        let fm = FileManager.default
        for link in links {
            // Only wallpapers still in the folder: anything the user trashed stays gone.
            let records = libraries[link.id].map { Array($0.records.values) } ?? []
            let redo = records.filter { record in
                guard record.status == .done, let output = record.output else { return false }
                return fm.fileExists(atPath: link.folder.appending(path: output).path(percentEncoded: false))
            }
            redoState[link.id] = Redo(
                outputs: Dictionary(uniqueKeysWithValues: redo.compactMap { r in r.output.map { (r.pin.id, $0) } }),
                croppedAnyway: Set(redo.filter { $0.note.contains(PipelineOptions.croppedAnywayMarker) }.map(\.pin.id)),
                crops: redo.reduce(into: [:]) { $0[$1.pin.id] = $1.crop })
            try? libraries[link.id]?.remove(redo.map(\.pin.id))

            if fitOwnImages {
                let originals = LocalFitter.originalsFolder(for: link.folder)
                let files = (try? fm.contentsOfDirectory(
                    at: originals, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                for original in files {
                    let fitted = link.folder.appending(path: original.deletingPathExtension().lastPathComponent + ".jpg")
                    guard fm.fileExists(atPath: fitted.path(percentEncoded: false)) else { continue }
                    try? fm.trashItem(at: fitted, resultingItemURL: nil)
                    try? fm.moveItem(at: original, to: link.folder.appending(path: original.lastPathComponent))
                }
            }
        }
        skippedLocalFiles = []
        lastSync = nil
        await sync()
        redoState = [:]
        if errorMessage == nil { renderedTarget = target; store(target, key: "renderedTarget") }
    }

    /// What `reprocessEverything` and `recrop` are redoing, per board.
    private struct Redo {
        /// Which file each redone pin overwrites, so files keep their names (desktops showing one
        /// image point at it by path).
        var outputs: [String: String] = [:]
        /// Pins that were cropped anyway: they're redone the same way.
        var croppedAnyway: Set<String> = []
        /// Hand-picked crops, by pin.
        var crops: [String: CGRect] = [:]
    }
    @ObservationIgnored private var redoState: [String: Redo] = [:]

    // MARK: Wallpapers

    func reloadWallpapers() {
        guard !isDemo else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var all: [Wallpaper] = [], left: [(board: String?, record: PinRecord)] = []
        let sources: [(id: String?, folder: URL)] = links.isEmpty ? [(nil, outputFolder)] : links.map { ($0.id, $0.folder) }
        for (id, folder) in sources {
            let library = id.flatMap { libraries[$0] }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            let byOutput = Dictionary((library.map { Array($0.records.values) } ?? []).compactMap { r in r.output.map { ($0, r) } },
                                      uniquingKeysWith: { a, _ in a })
            all += files
                .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
                .map { url in
                    let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                    return Wallpaper(url: url, modified: date, record: byOutput[url.lastPathComponent], linkID: id)
                }
            left += (library?.recent.filter { $0.status != .done } ?? []).map { (id, $0) }
        }
        allWallpapers = all.sorted { $0.modified > $1.modified }
        leftOutEntries = left
    }

    /// Makes wallpapers from pins that were skipped for their shape, cropping them however much
    /// that cuts away.
    func useAnyway(_ records: [PinRecord]) async {
        guard !isDemo, !isBusy else { return }
        var counts = Counts()
        for link in links {
            let pins = records.filter { libraries[link.id]?.records[$0.pin.id]?.status == .skippedShape }.map(\.pin)
            guard !pins.isEmpty else { continue }
            try? libraries[link.id]?.remove(pins.map(\.id))
            counts += await process(pins, in: link, minKeep: 0)
        }
        lastResult = counts.parts.joined(separator: " · ")
        reloadWallpapers()
    }

    /// Makes a wallpaper again from its original with a crop picked by hand. The file keeps its name,
    /// so a desktop showing it keeps pointing at it (and is told to reload it).
    func recrop(_ record: PinRecord, boardID: String?, to crop: CGRect) async {
        guard !isDemo, !isBusy, let output = record.output, let link = links.first(where: { $0.id == boardID }) else { return }
        redoState[link.id] = Redo(outputs: [record.pin.id: output], crops: [record.pin.id: crop])
        _ = await process([record.pin], in: link)
        redoState[link.id] = nil
        let saved = libraries[link.id]?.records[record.pin.id]?.status == .done
        lastResult = saved ? "Crop saved" : "Couldn't save the crop"
        reloadWallpapers()
        let file = link.folder.appending(path: output)
        if saved, file == currentWallpaper || file == pinnedWallpaper { show(file) }
    }

    /// Moves a wallpaper to the Trash. Its pin stays "seen", so it isn't downloaded again.
    func trash(_ wallpaper: Wallpaper) {
        if rotationMode == .macOS, wallpaper.url == pinnedWallpaper { resumeRotation() }
        if rotationMode == .pinstill, wallpaper.url == currentWallpaper { nextWallpaper() }
        if isDemo {
            allWallpapers.removeAll { $0.url == wallpaper.url }
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
        let folders = rotationFolders, interval = macInterval, randomly = macRandomly
        Task {
            let changed = await Task.detached { () -> Int? in
                var changed = 0
                for folder in folders {
                    guard let count = try? MacRotation.rotateAll(folder: folder, interval: interval, randomly: randomly) else { return nil }
                    changed += count
                }
                if changed > 0 { MacRotation.restartAgent() }
                return changed
            }.value
            if changed == nil { errorMessage = "Couldn't change macOS's wallpaper settings." }
            await checkStuckDesktops()
        }
    }

    func checkStuckDesktops() async {
        guard !isDemo, rotationMode == .macOS else { stuckDesktops = 0; return }
        let folders = rotationFolders
        stuckDesktops = await Task.detached { folders.reduce(0) { $0 + MacRotation.stuckDesktops(in: $1) } }.value
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
        let folders = rotationFolders, interval = macInterval, randomly = macRandomly
        let changed = await Task.detached { () -> Int? in
            var changed = 0
            for folder in folders {
                guard let count = try? MacRotation.apply(folder: folder, interval: interval, randomly: randomly) else { return nil }
                changed += count
            }
            if changed > 0 { MacRotation.restartAgent() }
            return changed
        }.value
        switch changed {
        case nil: errorMessage = "Couldn't change macOS's wallpaper settings."
        case 0?: errorMessage = "No desktop rotates through this folder yet. Use “Make it my wallpaper” first."
        default: errorMessage = nil
        }
    }

    /// Every folder macOS should rotate through: one per board, or the starting folder before a board is linked.
    private var rotationFolders: [URL] { links.isEmpty ? [outputFolder] : links.map(\.folder) }

    /// What macOS currently has for this folder, to show in Settings.
    func loadMacRotation() {
        guard !isDemo, let current = rotationFolders.lazy.compactMap({ MacRotation.current(for: $0) }).first else { return }
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
        let pool = allWallpapers.map(\.url)
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
        applyHotKeys()
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

    func openFolder(_ folder: URL? = nil) {
        let folder = folder ?? outputFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Picks another folder for a board (the first one when `link` is nil). A folder another board
    /// already uses, or one inside or around it, is refused.
    func chooseFolder(for link: BoardLink? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = link?.folder ?? outputFolder
        panel.prompt = "Use Folder"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let owner = link ?? links.first, let problem = BoardLinks.folderProblem(url, existing: links, ignoring: owner.id) {
            let alert = NSAlert()
            alert.messageText = "Pick another folder"
            alert.informativeText = problem
            alert.runModal()
            return
        }
        if let link, link.id != links.first?.id, let index = links.firstIndex(where: { $0.id == link.id }) {
            links[index].setFolder(url)
            skippedLocalFiles = []
            reloadWallpapers()
        } else {
            outputFolder = url
        }
    }

    // MARK: System events

    private func observeSystemEvents() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.macWoke() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.target = Screens.largestPixelSize() }
        }
    }

    private func macWoke() {
        guard syncOnWake, hasCompletedSetup, WakeSync.isDue(lastSync: lastSync, now: .now) else { return }
        Task {
            // The network and Pinterest's session need a moment after a wake.
            try? await Task.sleep(for: .seconds(20))
            guard syncOnWake, !isBusy, pendingImport == nil, WakeSync.isDue(lastSync: lastSync, now: .now) else { return }
            quiet = true
            addedThisRun = 0
            await refresh()
            quiet = false
            if notifyOnNew, addedThisRun > 0, !popoverIsShown() {
                Notifier.post(title: addedThisRun == 1 ? "1 new wallpaper" : "\(addedThisRun) new wallpapers",
                              body: links.count == 1 ? "Saved from \(links[0].board.name)." : "Saved from your boards.")
            }
        }
    }

    private func applyHotKeys() {
        guard !isDemo else { return }
        // Registered only while they do something, so they don't take the combination away from
        // other apps when macOS is the one rotating.
        guard hotKeysEnabled, rotationMode == .pinstill else { HotKeys.shared.disable(); return }
        HotKeys.shared.enable(next: { [weak self] in
            self?.nextWallpaper()
        }, removeCurrent: { [weak self] in
            guard let self,
                  let wallpaper = allWallpapers.first(where: { $0.url == self.currentWallpaper }) else { return }
            trash(wallpaper)
        })
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
            if !quiet { errorMessage = "Can't reach Pinterest. Check your internet connection and try again." }
        case is SessionError, is PinterestAPIError, is DecodingError:
            errorMessage = "Pinterest changed something on their end, so Pinstill can't read your board right now. An update to Pinstill will fix it."
            errorLink = Self.issuesURL
        default:
            if (error as NSError).domain == "WKErrorDomain" {
                // fetch() inside the page failing: offline, or Pinterest refusing the request.
                if !quiet {
                    errorMessage = "Couldn't get your board from Pinterest. If you're online, Pinterest may have changed something."
                    errorLink = Self.issuesURL
                }
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

    func loadDemoRenderedTarget(_ size: PixelSize) { renderedTarget = size }

    func loadDemoUpscaylMissing(_ install: UpscaylInstall) {
        upscaler = nil
        upscaylInstall = install
    }

    func loadDemo(account: Account, boards: [Board], board: Board?, wallpapers: [Wallpaper],
                  skipped: [PinRecord], activity: Activity, lastResult: String?, pendingImport: [Pin]? = nil,
                  extraBoards: [Board] = []) {
        self.account = account
        self.boards = boards
        var demoLinks: [BoardLink] = []
        for board in [board].compactMap({ $0 }) + extraBoards {
            let folder = demoLinks.isEmpty ? outputFolder
                : BoardLinks.defaultFolder(for: board, base: outputFolder, existing: demoLinks)
            demoLinks.append(BoardLink(board: board, folder: folder, libraryName: "demo-\(board.id).json"))
        }
        self.links = demoLinks
        self.allWallpapers = wallpapers.enumerated().map { index, wallpaper in
            var wallpaper = wallpaper
            wallpaper.linkID = links.isEmpty ? nil : links[index % links.count].id
            return wallpaper
        }
        self.leftOutEntries = skipped.map { (links.first?.id, $0) }
        self.activity = activity
        self.lastResult = lastResult
        self.lastSync = .now.addingTimeInterval(-120)
        self.pendingImport = pendingImport
        self.pendingImportLink = pendingImport == nil ? nil : links.first
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
