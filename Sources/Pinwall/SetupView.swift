import PinwallCore
import SwiftUI

/// First run. Every choice here is also in Settings, so nothing is final.
struct SetupView: View {
    enum Step: Int, CaseIterable {
        case welcome, upscayl, pinterest, folder, board, done

        var title: String {
            switch self {
            case .welcome: "Pinterest boards, as wallpapers"
            case .upscayl: "Upscaling"
            case .pinterest: "Your Pinterest account"
            case .folder: "The wallpaper folder"
            case .board: "The board"
            case .done: "That's it"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome: "What Pinwall does, and what it doesn't."
            case .upscayl: "Most pins are smaller than a Mac screen. Upscayl, a free app, enlarges them with AI."
            case .pinterest: "Pinwall reads your board the way pinterest.com does, so secret boards and private profiles work."
            case .folder: "Finished wallpapers go here, and macOS rotates through them."
            case .board: "Only pins on this board become wallpapers. A new secret board just for this works well."
            case .done: "Save pins, open Pinwall, and they show up on your desktop."
            }
        }
    }

    let onFinish: () -> Void
    @Environment(AppModel.self) private var model
    @State var step: Step = .welcome
    @State private var useAsDesktopWallpaper = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                progress.padding(.bottom, 14)
                Text(step.title)
                    .font(.system(size: 22, weight: .semibold))
                Text(step.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 22)

            Group {
                switch step {
                case .welcome: welcome
                case .upscayl: upscayl
                case .pinterest: pinterest
                case .folder: folder
                case .board: board
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        .padding(.horizontal, 40)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(width: 600, height: 620)
    }

    /// One pin per step: pinned for done and current, an empty hole for what's left.
    private var progress: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.self) { s in
                PinDot(size: 9, filled: s.rawValue <= step.rawValue)
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        Rows {
            Row(label: "You save", text: "Pins go on one Pinterest board, from your phone or your computer.")
            Row(label: "Pinwall fits", text: "Each pin is cropped to this Mac's screen, \(model.target.width)×\(model.target.height), and upscaled when it's too small. Tall phone wallpapers are skipped.")
            Row(label: "macOS rotates", text: "Wallpapers land in one folder that your Mac cycles through. Pinwall only has to be open while it syncs.")
            Row(label: "Good to know", text: "Pinwall isn't made by Pinterest. It uses the Pinterest website, so a change on their end can stop syncing until Pinwall is updated.")
        }
    }

    private var upscayl: some View {
        Rows {
            if let upscaler = model.upscaler {
                Row(label: "Found", text: "Upscayl \(upscaler.version ?? "") with \(upscaler.installedModels.count) models. Pinwall picks Digital art for anime and illustrations and High fidelity for photos, per image.")
            } else {
                Row(label: "Not found", text: "Without Upscayl, small pins are only resized and look soft. Install it, then check again.") {
                    HStack(spacing: 14) {
                        Button("Download Upscayl") { NSWorkspace.shared.open(Upscaler.downloadURL) }
                        Button("Check again") { model.refreshUpscaler() }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var pinterest: some View {
        Group {
            if let username = model.account.username {
                Rows {
                    Row(label: "Account", text: "Logged in as \(username). The login stays in Pinwall's own storage on this Mac.")
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    WebViewHost(webView: model.session.webView)
                        .frame(height: 330)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline))
                        .loginWatcher { }
                    Text("This is pinterest.com itself. Pinwall never sees your password.")
                        .meta(size: 11)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var folder: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(model.outputFolder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .meta(size: 12.5)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { model.chooseOutputFolder() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline))

            Toggle(isOn: $useAsDesktopWallpaper) {
                Text("Make it my desktop wallpaper")
                Text("Rotates through the folder. How often is up to you, in Pinwall's settings.")
            }
            Toggle(isOn: $model.fitOwnImages) {
                Text("Fit images I put in the folder myself, too")
                Text("They get cropped and upscaled like pins. The originals move to \(LocalFitter.originalsFolder(for: model.outputFolder).lastPathComponent).")
            }
        }
        .toggleStyle(.checkbox)
    }

    private var board: some View {
        Group {
            if let pending = model.pendingImport {
                ImportPrompt(pins: pending)
            } else if model.boards.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading your boards").foregroundStyle(.secondary)
                    Button("Reload") { Task { await model.loadBoards() } }.buttonStyle(.link)
                }
            } else {
                BoardList(maxHeight: 260)
            }
        }
    }

    private var done: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 18) {
            Rows {
                Row(label: "Save", text: "Put pins on \(model.board?.name ?? "your board"). Landscape images work best.")
                Row(label: "Open", text: "Pinwall checks the board when it starts and each time you click its icon in the menu bar.")
                Row(label: "Quit", text: "When it's done, if you like. Your Mac keeps rotating the wallpapers.")
            }
            Toggle("Open Pinwall when I log in", isOn: $model.launchAtLogin)
                .toggleStyle(.checkbox)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step == .welcome {
                Button("Skip for now") { onFinish() }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
            } else if step != .done {
                Button("Back") { move(-1) }
            }
            Spacer()
            Button(primaryTitle) { primaryAction() }
                .buttonStyle(.pin)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Set it up"
        case .upscayl: model.upscaler == nil ? "Continue without it" : "Continue"
        case .done: "Done"
        default: "Continue"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .pinterest: model.account.username != nil
        case .board: model.board != nil && model.pendingImport == nil
        default: true
        }
    }

    private func primaryAction() {
        switch step {
        case .folder:
            if useAsDesktopWallpaper { model.useFolderAsDesktopWallpaper() }
            move(1)
        case .done:
            model.hasCompletedSetup = true
            onFinish()
        default:
            move(1)
        }
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { step = next }
        if next == .pinterest { Task { await model.checkAccount() } }
        if next == .board {
            Task {
                await model.checkAccount()
                await model.resumePendingImport()
            }
        }
    }
}

// MARK: - Rows

/// Rows stacked with a hairline above the first; each `Row` draws the one below itself.
private struct Rows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            content
        }
    }
}

/// Label in a narrow left column, text beside it.
private struct Row<Extra: View>: View {
    let label: String
    let text: String
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(spacing: 0) {
            line
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 11)
            Hairline()
        }
    }

    private var line: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                extra
            }
        }
    }
}

extension Row where Extra == EmptyView {
    init(label: String, text: String) {
        self.init(label: label, text: text) { EmptyView() }
    }
}
