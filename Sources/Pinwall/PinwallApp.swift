import AppKit
import Observation
import SwiftUI

@main
struct PinwallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI is a status item + popover and AppKit-managed windows (see AppDelegate);
        // SwiftUI needs at least one scene.
        Settings { EmptyView() }
    }
}

/// Status item with an NSPopover rather than `MenuBarExtra(.window)`: the popover follows the
/// content's size as it changes, which MenuBarExtra windows don't.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var windows: [String: NSWindow] = [:]
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            Task { await Snapshots.render(to: URL(filePath: arguments[index + 1])); NSApp.terminate(nil) }
            return
        }

        model = AppModel()
        model.presentLogin = { [weak self] in self?.showLogin() }
        model.presentSetup = { [weak self] in self?.showSetup() }
        model.presentSettings = { [weak self] in self?.showSettings() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        updateIcon()

        let hosting = NSHostingController(rootView: MenuView().environment(model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
        // The size animation made the popover jump whenever its content re-measured
        // (opening a menu inside it, a sync finishing).
        popover.animates = false

        if model.hasCompletedSetup {
            Task { await model.refresh() } // sync on launch
        } else {
            showSetup()
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        // A transient popover only closes on outside clicks while its app is active,
        // and a menu bar app usually isn't.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { await model.refresh() } // sync whenever the menu opens
    }

    func popoverDidShow(_ notification: Notification) {
        // Clicks in other apps never reach us, so watch for them globally and close.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    // MARK: Windows

    private func showSetup() {
        show("setup", title: "Set up Pinwall", resizable: false) { [unowned self] in
            AnyView(SetupView { [weak self] in
                self?.windows["setup"]?.close()
                Task { await self?.model.refresh() }
            }.environment(model))
        }
    }

    private func showSettings() {
        show("settings", title: "Pinwall settings", resizable: false) { [unowned self] in
            AnyView(SettingsView().environment(model))
        }
    }

    private func showLogin() {
        show("login", title: "Log in to Pinterest", resizable: true, size: NSSize(width: 520, height: 760)) { [unowned self] in
            AnyView(LoginView { [weak self] in
                self?.windows["login"]?.close()
                Task { await self?.model.refresh() }
            }.environment(model))
        }
    }

    private func show(_ id: String, title: String, resizable: Bool, size: NSSize? = nil, content: () -> AnyView) {
        popover.performClose(nil)
        let window = windows[id] ?? {
            let hosting = NSHostingController(rootView: content())
            hosting.sizingOptions = size == nil ? [.preferredContentSize] : []
            let window = NSWindow(contentViewController: hosting)
            window.title = title
            window.styleMask = resizable ? [.titled, .closable, .resizable, .miniaturizable] : [.titled, .closable]
            if let size { window.setContentSize(size) }
            window.isReleasedWhenClosed = false
            window.center()
            windows[id] = window
            return window
        }()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Swap the icon while syncing; re-arms itself on every change of `isBusy`.
    private func updateIcon() {
        let busy = withObservationTracking {
            model.isBusy
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
        let name = busy ? "photo.badge.arrow.down" : "photo.on.rectangle.angled"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Pinwall")
    }
}
