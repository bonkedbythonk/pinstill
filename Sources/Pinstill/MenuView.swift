import PinstillCore
import SwiftUI

/// The status item popover: the wall of recent wallpapers, and what Pinstill is doing.
struct MenuView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Hairline()
            content
                .padding(16)
            if let error = model.errorMessage {
                Hairline()
                VStack(alignment: .leading, spacing: 4) {
                    Text(error)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if let link = model.errorLink {
                        Link("Check for a fix or report it", destination: link)
                    }
                }
                .font(.callout)
                .padding(16)
            }
        }
        .frame(width: 360)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            AppIconView(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pinstill").font(.system(size: 14, weight: .semibold))
                if let board = model.board, model.hasCompletedSetup {
                    Text(board.name + (board.isSecret ? " · secret board" : ""))
                        .meta(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if model.rotationMode == .pinstill, !model.wallpapers.isEmpty {
                Button {
                    model.nextWallpaper()
                } label: {
                    Image(systemName: "forward.end")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("Next wallpaper")
            }
            if model.hasCompletedSetup, model.account.username != nil, model.board != nil {
                if model.isBusy {
                    // The arrow glyph isn't centred in its box, so spinning it wobbled.
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Button {
                        Task { await model.sync() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .help("Check the board for new pins")
                }
            }
            // A plain button that pops an AppKit menu: a SwiftUI Menu in the popover ignored the
            // first click while the popover wasn't the key window yet, so it took two.
            Button {
                showMoreMenu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
        }
    }

    private func showMoreMenu() {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Settings…", key: ",") { model.presentSettings() })
        menu.addItem(ActionMenuItem("Open wallpaper folder") { model.openOutputFolder() })
        menu.addItem(ActionMenuItem("Run setup again…") { model.presentSetup() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Quit Pinstill", key: "q") { NSApp.terminate(nil) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !model.hasCompletedSetup {
            Prompt(title: "Not set up yet",
                   text: "Pick a Pinterest board, and every pin you save to it turns into a wallpaper sized for this Mac.",
                   button: ("Set up Pinstill", model.presentSetup))
        } else {
            switch model.account {
            case .unknown:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to Pinterest").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            case .loggedOut:
                Prompt(title: "Logged out of Pinterest",
                       text: "Pinterest ended the session. Log in again and Pinstill picks up where it left off.",
                       button: ("Log in", model.presentLogin))
            case .loggedIn:
                if model.board == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Which board holds your wallpapers?").font(.system(size: 13, weight: .semibold))
                        BoardList(maxHeight: 240)
                    }
                } else if let pending = model.pendingImport {
                    ImportPrompt(pins: pending)
                } else {
                    Wall()
                }
            }
        }
    }
}

// MARK: - The wall

private struct Wall: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusLine()
            if let update = model.availableUpdate {
                Notice(text: "Pinstill \(update.version) is out.",
                       action: ("Get it", { NSWorkspace.shared.open(update.page) }))
            }
            if model.rotationMode == .macOS, model.stuckDesktops > 0 {
                Notice(text: model.stuckDesktops == 1
                           ? "One desktop isn't rotating."
                           : "\(model.stuckDesktops) desktops aren't rotating.",
                       action: ("Rotate all", model.resumeRotation))
            }
            if model.upscaler == nil {
                Notice(text: "Upscayl isn't installed, so small pins are only resized.",
                       action: ("Get Upscayl", { NSWorkspace.shared.open(Upscaler.downloadURL) }))
            }
            if model.wallpapers.isEmpty {
                Text("Nothing here yet. Save a few pins to \(model.board?.name ?? "your board") on Pinterest, then click the arrow above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 18)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                              alignment: .leading, spacing: 12) {
                        ForEach(model.wallpapers) { wallpaper in
                            WallpaperPrint(wallpaper: wallpaper)
                        }
                    }
                    .padding(.top, 5) // room for the pin dot above the first row
                }
                .scrollIndicators(.automatic)
                // Popovers size to fit, which collapses a bare ScrollView: give it the grid's
                // height, up to three and a half rows so it's clear there's more below.
                .frame(height: gridHeight)
                Hairline()
                HStack(spacing: 4) {
                    Text("\(model.wallpapers.count) on the wall")
                    if let next = model.nextChange {
                        Text("· next")
                        Text(next, style: .relative)
                    }
                    if !model.skippedPins.isEmpty {
                        Text("· \(model.skippedPins.count) skipped").help(skippedHelp)
                    }
                    Spacer()
                    Button("Show in Finder") { model.openOutputFolder() }
                        .buttonStyle(.link)
                }
                .meta()
                .foregroundStyle(.secondary)
            }
        }
    }

    /// A print is about 124pt tall at this width (16:10 image, mat, caption), rows 12pt apart.
    private var gridHeight: CGFloat {
        let rows = CGFloat((model.wallpapers.count + 1) / 2)
        return min(rows * 124 + (rows - 1) * 12 + 5, 3.5 * 136)
    }

    private var skippedHelp: String {
        model.skippedPins.prefix(8).map(\.note).joined(separator: "\n")
    }
}

private struct StatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .meta(size: 12)
                .foregroundStyle(model.isBusy ? .primary : .secondary)
                .lineLimit(1)
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Theme.pinRed)
            }
        }
    }

    private var text: String {
        switch model.activity {
        case .idle:
            let result = model.lastResult ?? "Ready"
            guard let lastSync = model.lastSync else { return result }
            return "\(result) · \(lastSync.formatted(.relative(presentation: .named)))"
        case .checking: return "Checking \(model.board?.name ?? "the board")…"
        case .processing(let done, let total): return "Upscaling pin \(done + 1) of \(total)…"
        case .fitting(let done, let total): return "Fitting your image \(done + 1) of \(total)…"
        }
    }

    private var fraction: Double? {
        switch model.activity {
        case .processing(let done, let total), .fitting(let done, let total):
            Double(done) / Double(max(total, 1))
        default: nil
        }
    }
}

struct ImportPrompt: View {
    let pins: [Pin]
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(model.board?.name ?? "This board") already has \(pins.count) pins")
                .font(.system(size: 13, weight: .semibold))
            Text("Turn them all into wallpapers now, or start from the next pin you save? Each pin that needs upscaling takes around 5 to 15 seconds.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Start from the next pin") { Task { await model.importExisting(false) } }
                Spacer()
                Button("Import all \(pins.count)") { Task { await model.importExisting(true) } }
                    .buttonStyle(.pin)
            }
        }
    }
}

// MARK: - Building blocks

/// A heading, a sentence and one button. Used for states that need the user to act.
struct Prompt: View {
    let title: String
    let text: String
    let button: (String, () -> Void)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(button.0, action: button.1)
                .buttonStyle(.pin)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line of text with an action at the end of it. No box, no icon.
struct Notice: View {
    let text: String
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text).foregroundStyle(.secondary)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.link)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// An NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
