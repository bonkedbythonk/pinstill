import PinwallCore
import SwiftUI

struct SettingsView: View {
    enum Tab: Hashable { case general, rotation, pinterest, upscaling, about }

    @State var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            RotationSettings()
                .tabItem { Label("Rotation", systemImage: "arrow.2.squarepath") }
                .tag(Tab.rotation)
            PinterestSettings()
                .tabItem { Label("Pinterest", systemImage: "pin") }
                .tag(Tab.pinterest)
            UpscalingSettings()
                .tabItem { Label("Upscaling", systemImage: "wand.and.stars") }
                .tag(Tab.upscaling)
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("Wallpaper folder") {
                    HStack {
                        Text(model.outputFolder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { model.chooseOutputFolder() }
                    }
                }
                LabeledContent("Desktop") {
                    HStack {
                        Button("Make it my wallpaper") { model.useFolderAsDesktopWallpaper() }
                        Button("Wallpaper settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
                        }
                    }
                }
            } footer: {
                Text("Wallpapers are made at \(model.target.width)×\(model.target.height), the size of this Mac's largest display. How often they change is under Rotation.")
                    .settingsFooter()
            }
            Section {
                Toggle(isOn: $model.fitOwnImages) {
                    Text("Fit images I put in the folder myself, too")
                    Text("Cropped and upscaled like pins. The originals move to \(LocalFitter.originalsFolder(for: model.outputFolder).lastPathComponent).")
                }
                Toggle("Open Pinwall when I log in", isOn: $model.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RotationSettings: View {
    @Environment(AppModel.self) private var model

    static let pinwallIntervals: [(String, TimeInterval)] = [
        ("Every minute", 60), ("Every 5 minutes", 300), ("Every 15 minutes", 900),
        ("Every 30 minutes", 1800), ("Every hour", 3600), ("Every 3 hours", 10800), ("Every day", 86400),
    ]

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Who switches wallpapers", selection: $model.rotationMode) {
                    Text("macOS").tag(AppModel.RotationMode.macOS)
                    Text("Pinwall").tag(AppModel.RotationMode.pinwall)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(model.rotationMode == .macOS
                     ? "macOS rotates through the folder by itself, so Pinwall can be closed."
                     : "Pinwall picks the next wallpaper itself. It has to stay open in the menu bar for that, so turn on Open Pinwall when I log in in General.")
                    .settingsFooter()
            }

            if model.rotationMode == .macOS {
                Section {
                    Picker("Change wallpaper", selection: Binding(
                        get: { model.macInterval ?? .every30Minutes },
                        set: { model.macInterval = $0; Task { await model.applyMacRotation() } })) {
                        ForEach(ShuffleInterval.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("In random order", isOn: Binding(
                        get: { model.macRandomly ?? true },
                        set: { model.macRandomly = $0; Task { await model.applyMacRotation() } }))
                } footer: {
                    Text("These are the same settings as System Settings, Wallpaper, for desktops that use this folder. macOS has no public way to change them, so Pinwall edits its settings file and restarts the wallpaper process; your desktop may blink once. A macOS update could stop this from working.")
                        .settingsFooter()
                }
            } else {
                Section {
                    Picker("Change wallpaper", selection: $model.pinwallInterval) {
                        ForEach(Self.pinwallIntervals, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    Picker("Order", selection: $model.pinwallOrder) {
                        Text("Random").tag(AppModel.RotationOrder.random)
                        Text("Newest first").tag(AppModel.RotationOrder.newestFirst)
                    }
                    LabeledContent("Now") {
                        Button("Next wallpaper") { model.nextWallpaper() }
                            .disabled(model.wallpapers.isEmpty)
                    }
                } footer: {
                    Text("Every desktop gets the current wallpaper when you switch to it.")
                        .settingsFooter()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadMacRotation() }
    }
}

private struct PinterestSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Account") {
                if let username = model.account.username {
                    LabeledContent("Logged in as") {
                        HStack {
                            Text(username)
                            Button("Log out") { Task { await model.logOut() } }
                        }
                    }
                } else {
                    LabeledContent("Not logged in") {
                        Button("Log in…") { model.presentLogin() }
                    }
                }
            }
            if model.account.username != nil {
                Section {
                    BoardList(maxHeight: 220)
                    if let pending = model.pendingImport {
                        ImportPrompt(pins: pending)
                    }
                } header: {
                    HStack {
                        Text("Board")
                        Spacer()
                        Button("Reload") { Task { await model.loadBoards() } }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                } footer: {
                    Text("Pins saved to this board become wallpapers the next time Pinwall syncs.")
                        .settingsFooter()
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpscalingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRedo = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Upscayl") {
                if let upscaler = model.upscaler {
                    LabeledContent("Installed") {
                        Text("Version \(upscaler.version ?? "?") · \(upscaler.installedModels.count) models")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Not installed") {
                        HStack {
                            Button("Download…") { NSWorkspace.shared.open(Upscaler.downloadURL) }
                            Button("Check again") { model.refreshUpscaler() }
                        }
                    }
                }
            }
            Section {
                Picker("Model", selection: $model.upscaleModel) {
                    Text("Automatic").tag(UpscaleModel.automatic)
                    Divider()
                    ForEach(model.installedModels, id: \.self) { name in
                        Text(UpscaleModel.displayName(name)).tag(UpscaleModel.fixed(name))
                    }
                }
                .disabled(model.upscaler == nil)
            } footer: {
                Text("Automatic looks at each image: Digital art for anime, drawings and graphic art, High fidelity for photos like landscapes and cities.")
                    .settingsFooter()
            }
            Section {
                LabeledContent("Redo all wallpapers") {
                    Button("Upscale everything again…") { confirmRedo = true }
                        .disabled(model.isBusy || model.board == nil)
                }
            } footer: {
                Text("Makes every wallpaper again from its original, for example after changing the model or moving to a bigger display. Wallpapers you removed stay removed.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Upscale every wallpaper again?", isPresented: $confirmRedo) {
            Button("Upscale again") { Task { await model.reprocessEverything() } }
        } message: {
            Text("This can take a few minutes. Each wallpaper is swapped for its new version when it's ready.")
        }
    }
}

private struct AboutView: View {
    static let repo = URL(string: "https://github.com/bonkedbythonk/pinwall")!

    var body: some View {
        VStack(spacing: 10) {
            AppIconView(size: 80)
            Text("Pinwall").font(.title.weight(.bold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Pinterest boards, as wallpapers.")
                .multilineTextAlignment(.center)
            HStack {
                Link("GitHub", destination: Self.repo)
                Text("·").foregroundStyle(.secondary)
                Link("Upscayl", destination: Upscaler.downloadURL)
            }
            Text("Not made by Pinterest or Upscayl. Pinwall uses the Pinterest website the way a browser does, so a change on their end can stop syncing until Pinwall is updated.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

private extension View {
    /// Grouped-form footers centre or right-align multi-line text; keep it reading left to right.
    func settingsFooter() -> some View {
        foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
