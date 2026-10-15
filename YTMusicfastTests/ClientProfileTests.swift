import Foundation
import Testing

@Suite("Client profiles (clients.json)")
struct ClientProfileTests {
    @Test func theRepositoryFileMatchesTheBuiltInClient() throws {
        // The file published in the repository, as the app reads it.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("clients.json")
        let profiles = try #require(ClientProfiles.decode(try Data(contentsOf: url)))
        #expect(profiles == ClientProfile.builtIn)
    }

    @Test func refusesAnythingButPlainValues() {
        let good = ClientProfile.builtIn[0]
        var bad = good
        bad.clientName = "VISIONOS\"; drop"
        #expect(!bad.isValid)
        bad = good
        bad.userAgent = "Mozilla\r\nX-Injected: 1"
        #expect(!bad.isValid)
        bad = good
        bad.clientNameId = "10a"
        #expect(!bad.isValid)
        #expect(good.isValid)
        #expect(ClientProfiles.decode(Data("{\"audio\": []}".utf8)) == nil)
        #expect(ClientProfiles.decode(Data("garbage".utf8)) == nil)
    }

    @Test func clientProblemsAreToldApartFromUnplayableSongs() {
        #expect(VisionOSStreamResolver.isClientProblem(InnerTubeError.http(400)))
        #expect(VisionOSStreamResolver.isClientProblem(InnerTubeError.noAudio))
        #expect(VisionOSStreamResolver.isClientProblem(InnerTubeError.unplayable("Sign in to confirm you're not a bot")))
        #expect(!VisionOSStreamResolver.isClientProblem(InnerTubeError.unplayable("This video has been removed")))
        #expect(!VisionOSStreamResolver.isClientProblem(URLError(.notConnectedToInternet)))
    }
}
