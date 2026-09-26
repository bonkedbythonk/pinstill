import PinwallCore
import SwiftUI

struct SettingsView: View {
    enum Tab: Hashable { case general, pinterest, upscaling, about }

    @State var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
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
                Text("Wallpapers are made at \(model.target.width)×\(model.target.height), the size of this Mac's largest display. How often macOS switches between them is up to Wallpaper settings.")
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Redo all wallpapers") {
                    Button("Upscale everything again…") { confirmRedo = true }
                        .disabled(model.isBusy || model.board == nil)
                }
            } footer: {
                Text("Makes every wallpaper again from its original, for example after changing the model or moving to a bigger display. Wallpapers you removed stay removed.")
                    .foregroundStyle(.secondary)
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
