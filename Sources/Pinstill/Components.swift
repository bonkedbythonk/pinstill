import AppKit
import ImageIO
import PinstillCore
import SwiftUI
import WebKit

// MARK: - Thumbnails

/// Small, cached previews of local wallpapers (decoding a 3024px JPEG per tile would be wasteful).
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for url: URL, modified: Date, maxPixel: Int = 640) async -> NSImage? {
        let key = "\(url.path(percentEncoded: false))|\(modified.timeIntervalSince1970)|\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        // Decode off the main thread, but hand back a CGImage: NSImage isn't Sendable on
        // pre-macOS 26 SDKs, which failed the Xcode 16 build.
        let decoded = await Task.detached(priority: .utility) { () -> SendableImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return nil }
            return SendableImage(cgImage: cg)
        }.value
        guard let cg = decoded?.cgImage else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }
}

/// CGImage is immutable, so crossing threads is safe even where the SDK doesn't say so.
private struct SendableImage: @unchecked Sendable {
    let cgImage: CGImage
}

struct WallpaperThumbnail: View {
    let wallpaper: Wallpaper
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.mat)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .task(id: wallpaper) {
            image = await ThumbnailCache.shared.image(for: wallpaper.url, modified: wallpaper.modified)
        }
    }
}

// MARK: - Print (wallpaper tile)

/// A wallpaper shown as a print on the wall: image in a thin mat, a caption line underneath.
/// Hovering lifts it and swaps the caption for its two actions.
struct WallpaperPrint: View {
    let wallpaper: Wallpaper
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var isOnDesktop: Bool { model.desktopWallpaper == wallpaper.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            WallpaperThumbnail(wallpaper: wallpaper)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .padding(3)
                .background(Theme.mat, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(alignment: .top) {
                    if isOnDesktop { PinDot(size: 11).offset(y: -4) }
                }
                .offset(y: hovering ? -2 : 0)
                .shadow(color: .black.opacity(hovering ? 0.25 : 0), radius: 8, y: 4)
                .onTapGesture { NSWorkspace.shared.open(wallpaper.url) }

            caption
                .meta(size: 10.5)
                .lineLimit(1)
                .frame(height: 14)
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Set as wallpaper") { model.setAsDesktop(wallpaper) }
            Button("Open") { NSWorkspace.shared.open(wallpaper.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([wallpaper.url]) }
            if let pin = wallpaper.record?.pin {
                Button("Open pin on Pinterest") { NSWorkspace.shared.open(pin.pinURL) }
            }
            Divider()
            Button("Move to Trash", role: .destructive) { model.trash(wallpaper) }
        }
        .help(wallpaper.record?.note ?? wallpaper.url.lastPathComponent)
    }

    @ViewBuilder
    private var caption: some View {
        if hovering {
            HStack(spacing: 10) {
                Button("Set as wallpaper") { model.setAsDesktop(wallpaper) }
                Button("Remove") { model.trash(wallpaper) }
            }
            .buttonStyle(.link)
        } else {
            HStack(spacing: 4) {
                Text(wallpaper.modified.formatted(.relative(presentation: .named)))
                    .foregroundStyle(.secondary)
                if isOnDesktop {
                    Text("· on desktop").foregroundStyle(Theme.pinRed)
                } else if wallpaper.isLowRes {
                    Text("· small original").foregroundStyle(Theme.warning)
                }
            }
        }
    }
}

// MARK: - Boards

struct BoardRow: View {
    let board: Board
    var selected = false

    var body: some View {
        HStack(spacing: 10) {
            PinDot(size: 9, filled: selected)
            Text(board.name).fontWeight(selected ? .semibold : .regular)
            Spacer()
            Text("\(board.pinCount) pin\(board.pinCount == 1 ? "" : "s")\(board.isSecret ? " · secret" : "")")
                .meta()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

struct BoardList: View {
    @Environment(AppModel.self) private var model
    var maxHeight: CGFloat = 260

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.boards.enumerated()), id: \.element.id) { index, board in
                    if index > 0 { Hairline() }
                    Button {
                        Task { await model.choose(board) }
                    } label: {
                        BoardRow(board: board, selected: model.board?.id == board.id)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // Hosting views size to fit, which collapses a bare ScrollView: give it an explicit height.
        .frame(height: min(CGFloat(model.boards.count) * 34, maxHeight))
    }
}

// MARK: - Misc

struct AppIconView: View {
    var size: CGFloat = 64

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
    }
}

/// Hosts the session's shared WKWebView (it can only live in one place at a time).
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

extension UpscaleModel {
    static func displayName(_ model: String) -> String {
        let words = model.replacingOccurrences(of: "-4x", with: "").split(separator: "-")
        return words.enumerated().map { i, w in i == 0 ? w.prefix(1).uppercased() + w.dropFirst() : String(w) }
            .joined(separator: " ")
    }
}
