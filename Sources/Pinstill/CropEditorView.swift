import AppKit
import PinstillCore
import SwiftUI

/// Adjust the crop of one wallpaper: a box the shape of the screen over the original, dragged
/// into place and zoomed with a slider. Saving makes the wallpaper again from the original.
struct CropEditorView: View {
    let record: PinRecord
    let boardID: String?
    /// Where the original already is (snapshots); otherwise it's downloaded from the pin.
    var originalURL: URL?
    var onClose: () -> Void = {}

    @Environment(AppModel.self) private var model

    private enum Phase {
        case loading
        case failed(String)
        case ready
    }

    @State private var phase = Phase.loading
    @State private var preview: NSImage?
    @State private var pixels = (width: 1, height: 1)
    @State private var automatic = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var center = CGPoint(x: 0.5, y: 0.5)
    @State private var zoom = 1.0
    @State private var dragStart: CGPoint?
    @State private var downloaded: URL?

    private var aspect: Double { model.target.aspect }

    private var rect: CGRect {
        CropGeometry.rect(imageWidth: pixels.width, imageHeight: pixels.height, aspect: aspect, zoom: zoom, center: center)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch phase {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Getting the original").foregroundStyle(.secondary)
                }
                .frame(width: 680, height: 200)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(width: 680, height: 200)
            case .ready:
                editor
            }
            HStack {
                Button("Use Pinstill's crop") { apply(automatic) }
                    .disabled(!isReady)
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.pin)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isReady || model.isBusy)
            }
        }
        .padding(20)
        .task { await load() }
        .onDisappear { if let downloaded { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) } }
    }

    private var isReady: Bool { if case .ready = phase { true } else { false } }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(CGFloat(pixels.width) / CGFloat(pixels.height), contentMode: .fit)
                    .frame(maxWidth: 680, maxHeight: 420)
                    .overlay { CropBox(rect: rect, onDrag: move(by:in:), onEnd: { dragStart = nil }) }
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 12) {
                Text("Zoom").foregroundStyle(.secondary)
                Slider(value: $zoom, in: CropGeometry.minimumZoom...1)
                    .onChange(of: zoom) { _, _ in center = CGPoint(x: rect.midX, y: rect.midY) }
                    .frame(width: 240)
                Spacer()
                caption
            }
            .font(.callout)
        }
    }

    private var caption: some View {
        let width = Int(rect.width * Double(pixels.width)), height = Int(rect.height * Double(pixels.height))
        let needed = Double(model.target.width) / Double(max(width, 1))
        return HStack(spacing: 4) {
            Text("\(width)×\(height) of the original")
            if needed > 4 { Text("· small, it will look soft").foregroundStyle(Theme.warning) }
        }
        .meta()
        .foregroundStyle(.secondary)
    }

    /// Moves the box with the drag; `surface` is how big the image is on screen.
    private func move(by translation: CGSize, in surface: CGSize) {
        guard surface.width > 0, surface.height > 0 else { return }
        let start = dragStart ?? center
        dragStart = start
        let moved = CropGeometry.rect(imageWidth: pixels.width, imageHeight: pixels.height, aspect: aspect, zoom: zoom,
                                      center: CGPoint(x: start.x + translation.width / surface.width,
                                                      y: start.y + translation.height / surface.height))
        center = CGPoint(x: moved.midX, y: moved.midY)
    }

    private func apply(_ normalized: CGRect) {
        zoom = CropGeometry.zoom(of: normalized, imageWidth: pixels.width, imageHeight: pixels.height, aspect: aspect)
        center = CGPoint(x: normalized.midX, y: normalized.midY)
    }

    private func save() {
        let crop = rect
        onClose()
        Task { await model.recrop(record, boardID: boardID, to: crop) }
    }

    // MARK: Loading

    private struct Loaded: @unchecked Sendable {
        let image: CGImage
        let automatic: CGRect
    }

    private func load() async {
        do {
            let file: URL
            if let originalURL {
                file = originalURL
            } else {
                let folder = URL.cachesDirectory.appending(path: "Pinstill/crop/\(record.pin.id)-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                file = try await ImageFetcher.download(record.pin.imageURL, to: folder, name: "original")
                downloaded = file
            }
            let target = model.target
            // The preview is the CGImage the wallpaper is cut from, not NSImage(contentsOf:), which
            // applies the EXIF rotation the pipeline doesn't, so the box would sit on the wrong part.
            let loaded = try await Task.detached(priority: .userInitiated) { () -> Loaded in
                let image = try Framer.loadImage(file)
                var box = CGRect(x: 0, y: 0, width: 1, height: 1)
                if case .crop(let rect, _) = Framer.decide(image, target: target, minKeep: 0) {
                    box = CGRect(x: rect.minX / Double(image.width), y: rect.minY / Double(image.height),
                                 width: rect.width / Double(image.width), height: rect.height / Double(image.height))
                }
                return Loaded(image: image, automatic: box)
            }.value
            pixels = (loaded.image.width, loaded.image.height)
            preview = NSImage(cgImage: loaded.image, size: NSSize(width: loaded.image.width, height: loaded.image.height))
            automatic = loaded.automatic
            let start = record.crop.map {
                CropGeometry.refit($0, imageWidth: pixels.width, imageHeight: pixels.height, aspect: aspect)
            } ?? automatic
            apply(start)
            phase = .ready
        } catch {
            phase = .failed("Couldn't get the original. The pin may have been deleted, or you may be offline.")
        }
    }
}

/// The dimmed surround, the box and its thirds, and the drag target.
private struct CropBox: View {
    let rect: CGRect
    let onDrag: (CGSize, CGSize) -> Void
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { geo in
            let box = CGRect(x: rect.minX * geo.size.width, y: rect.minY * geo.size.height,
                             width: rect.width * geo.size.width, height: rect.height * geo.size.height)
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    path.addRect(box)
                }
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                Path { path in
                    for fraction in [1.0 / 3, 2.0 / 3] {
                        path.move(to: CGPoint(x: box.minX + box.width * fraction, y: box.minY))
                        path.addLine(to: CGPoint(x: box.minX + box.width * fraction, y: box.maxY))
                        path.move(to: CGPoint(x: box.minX, y: box.minY + box.height * fraction))
                        path.addLine(to: CGPoint(x: box.maxX, y: box.minY + box.height * fraction))
                    }
                }
                .stroke(.white.opacity(0.35), lineWidth: 1)
                Rectangle().path(in: box).stroke(.white, lineWidth: 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { onDrag($0.translation, geo.size) }
                .onEnded { _ in onEnd() })
        }
    }
}
