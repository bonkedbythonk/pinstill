import Foundation
import Testing
@testable import PinstillCore

/// A store shaped like macOS 27's Index.plist: one Space rotating the Pinstill folder,
/// one rotating another folder, one on a single image.
private func makeStore() throws -> URL {
    func bplist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    func content(folder: String?, image: String? = nil, interval: String) throws -> [String: Any] {
        let config: [String: Any] = folder.map { ["type": "imageFolder", "url": ["relative": $0]] }
            ?? ["type": "imageFile", "url": ["relative": image!]]
        let options: [String: Any] = ["values": [
            "placement": ["picker": ["_0": ["id": "Crop"]]],
            "shuffleFrequency": ["picker": ["_0": ["id": interval]]],
        ]]
        return ["Desktop": ["Content": [
            "Choices": [["Configuration": try bplist(config), "Files": [], "Provider": "com.apple.wallpaper.choice.image"]],
            "EncodedOptionValues": try bplist(options),
            "Shuffle": "$null",
        ]]]
    }
    let root: [String: Any] = [
        "Spaces": [
            "A": ["Default": try content(folder: "file:///Users/me/Pictures/Pinstill/", interval: "shuffle_every_30_minutes")],
            "B": ["Default": try content(folder: "file:///Users/me/Other/", interval: "shuffle_every_1_hour")],
            "C": ["Default": try content(folder: nil, image: "file:///Users/me/a.jpg", interval: "shuffle_every_1_day")],
        ],
    ]
    let url = FileManager.default.temporaryDirectory.appending(path: "Index-\(UUID()).plist")
    try bplist(root).write(to: url)
    return url
}

private let pinstillFolder = URL(filePath: "/Users/me/Pictures/Pinstill", directoryHint: .isDirectory)

@Test func readsCurrentInterval() throws {
    let store = try makeStore()
    let settings = MacRotation.current(for: pinstillFolder, store: store)
    #expect(settings?.interval == .every30Minutes)
    #expect(settings?.randomly == nil)
}

@Test func appliesOnlyToDesktopsRotatingThatFolder() throws {
    let store = try makeStore()
    let changed = try MacRotation.apply(folder: pinstillFolder, interval: .every5Minutes, randomly: true, store: store)
    #expect(changed == 1)

    let after = MacRotation.current(for: pinstillFolder, store: store)
    #expect(after?.interval == .every5Minutes)
    #expect(after?.randomly == true)
    #expect(MacRotation.current(for: URL(filePath: "/Users/me/Other"), store: store)?.interval == .every1Hour)
}

@Test func unknownFolderChangesNothing() throws {
    let store = try makeStore()
    let before = try Data(contentsOf: store)
    let changed = try MacRotation.apply(folder: URL(filePath: "/nowhere"), interval: .every1Day, randomly: nil, store: store)
    #expect(changed == 0)
    #expect(try Data(contentsOf: store) == before)
}

@Test func everyIntervalHasALabel() {
    #expect(ShuffleInterval.allCases.count == 9)
    #expect(Set(ShuffleInterval.allCases.map(\.label)).count == 9)
}
