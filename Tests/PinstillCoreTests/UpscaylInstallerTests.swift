import Foundation
import Testing
@testable import PinstillCore

// Upscayl 2.15.0's latest-mac.yml, as published.
private let manifest = """
version: 2.15.0
files:
  - url: upscayl-2.15.0-mac.zip
    sha512: xiDQp/ununLXKxYkeVA/0o86dlChZ5V7YQOvN/FyxEendGDVPQeNgy/WEDPA3mz/JgqSv5sbF7PVKY/mxvLBGw==
    size: 376811048
  - url: upscayl-2.15.0-mac.dmg
    sha512: QzPPScqqEZCKBjKdQFCC8s2qWpSd8oLD2Oz7jAQGi2IGFoRrRjacKF+kT48O7MrrfPQUmv8rcyeQv0mHsES+Xw==
    size: 385264901
path: upscayl-2.15.0-mac.zip
sha512: xiDQp/ununLXKxYkeVA/0o86dlChZ5V7YQOvN/FyxEendGDVPQeNgy/WEDPA3mz/JgqSv5sbF7PVKY/mxvLBGw==
releaseDate: '2024-12-25T17:05:59.589Z'
"""

@Test func picksTheDiskImageFromTheManifest() throws {
    let download = try #require(UpscaylInstaller.parseManifest(manifest))
    #expect(download.version == "2.15.0")
    #expect(download.url.absoluteString == "https://github.com/upscayl/upscayl/releases/latest/download/upscayl-2.15.0-mac.dmg")
    #expect(download.sha512.hasPrefix("QzPPScqq"))
    #expect(download.size == 385_264_901)
}

@Test func diskImageListedFirstStillGetsItsOwnChecksum() throws {
    let reordered = """
    version: 3.0.0
    files:
      - url: upscayl-3.0.0-mac.dmg
        sha512: DMGSUM==
        size: 10
      - url: upscayl-3.0.0-mac.zip
        sha512: ZIPSUM==
        size: 20
    path: upscayl-3.0.0-mac.zip
    sha512: ZIPSUM==
    """
    let download = try #require(UpscaylInstaller.parseManifest(reordered))
    #expect(download.sha512 == "DMGSUM==")
    #expect(download.size == 10)
}

@Test func manifestWithoutDiskImageGivesNothing() {
    #expect(UpscaylInstaller.parseManifest("version: 1.0.0\nfiles:\n  - url: a.zip\n    sha512: X\n") == nil)
}

@Test func checksumMatchesKnownValue() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "pinstill-sha-\(UUID()).txt")
    try Data("abc".utf8).write(to: file)
    // SHA-512("abc"), base64.
    #expect(try UpscaylInstaller.sha512(of: file) == "3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw==")
}
