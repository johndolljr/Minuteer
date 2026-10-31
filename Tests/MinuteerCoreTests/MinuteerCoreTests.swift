import Testing
@testable import MinuteerCore

@Suite("Minuteer Core Tests")
struct MinuteerCoreTests {
    @Test("Version verification")
    func testVersion() {
        #expect(MinuteerVersion.version == "1.0.0")
        #expect(MinuteerVersion.formattedVersion() == "Minuteer v1.0.0")
        #expect(InjestAudioVersion.version == "1.0.0")
    }
}
