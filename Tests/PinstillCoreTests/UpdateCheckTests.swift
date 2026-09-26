import Testing
@testable import PinstillCore

@Test func comparesVersionsNumerically() {
    #expect(UpdateCheck.isNewer("0.2.0", than: "0.1.0"))
    #expect(UpdateCheck.isNewer("0.10.0", than: "0.9.2"))
    #expect(UpdateCheck.isNewer("1.0", than: "0.9.9"))
    #expect(!UpdateCheck.isNewer("0.1.0", than: "0.1.0"))
    #expect(!UpdateCheck.isNewer("0.1", than: "0.1.0"))
    #expect(!UpdateCheck.isNewer("0.1.0", than: "0.2.0"))
}

@Test func devBuildsAreNeverOutdated() {
    #expect(!UpdateCheck.isNewer("9.9.9", than: "dev"))
    #expect(!UpdateCheck.isNewer("beta", than: "0.1.0"))
}
