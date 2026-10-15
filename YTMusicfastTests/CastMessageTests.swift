import Foundation
import Testing

@Suite("Google Cast messages")
struct CastMessageTests {
    @Test func roundTrips() throws {
        let message = CastMessage(sourceId: "sender-0", destinationId: "receiver-0",
                                  namespace: "urn:x-cast:com.google.cast.tp.connection", payload: #"{"type":"CONNECT"}"#)
        let framed = message.framed()
        let length = framed.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        #expect(length == framed.count - 4)
        #expect(CastMessage.decode(framed.dropFirst(4)) == message)
    }

    @Test func longPayloadsUseMultiByteLengths() throws {
        let payload = String(repeating: "x", count: 5000)
        let message = CastMessage(sourceId: "a", destinationId: "b", namespace: "c", payload: payload)
        #expect(CastMessage.decode(message.framed().dropFirst(4))?.payload == payload)
    }

    @Test func rejectsGarbage() {
        #expect(CastMessage.decode(Data([0x12, 0x50, 0x41])) == nil)
        #expect(CastMessage.decode(Data([0x0F])) == nil)
    }

    @Test func byteRanges() {
        #expect(ByteRange.parse(nil, length: 100, limit: 1000) == 0...99)
        #expect(ByteRange.parse("bytes=0-", length: 100, limit: 10) == 0...9)
        #expect(ByteRange.parse("bytes=50-59", length: 100, limit: 1000) == 50...59)
        #expect(ByteRange.parse("bytes=90-200", length: 100, limit: 1000) == 90...99)
        #expect(ByteRange.parse("bytes=-10", length: 100, limit: 1000) == 90...99)
        #expect(ByteRange.parse("bytes=100-", length: 100, limit: 1000) == nil)
    }
}

@Suite("Finding Cast devices (mDNS)")
struct MDNSTests {
    /// Builds a response like a Chromecast's: PTR, SRV, TXT and A records, with name compression.
    private func response() -> Data {
        var data = Data([0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 3])
        let type = MDNS.encode(name: "_googlecast._tcp.local")
        let typeOffset = data.count
        data += type
        let instanceLabel = Data("Chromecast-abc".utf8)
        // PTR: type → instance (instance name = label + pointer to type)
        data += [0, 12, 0, 1, 0, 0, 0, 120]
        let instance = Data([UInt8(instanceLabel.count)]) + instanceLabel + Data([0xC0, UInt8(typeOffset)])
        data += [0, UInt8(instance.count)] + instance
        let instanceOffset = data.count - instance.count
        // SRV: instance → host:8009
        data += [0xC0, UInt8(instanceOffset), 0, 33, 0x80, 1, 0, 0, 0, 120]
        let host = MDNS.encode(name: "abc.local")
        data += [0, UInt8(6 + host.count), 0, 0, 0, 0, 0x1F, 0x49] + host
        let hostOffset = data.count - host.count
        // TXT: fn=Gym TV, md=Chromecast
        let entries = ["id=abc", "fn=Gym TV", "md=Chromecast"].map { Data([UInt8($0.utf8.count)]) + Data($0.utf8) }.reduce(Data(), +)
        data += [0xC0, UInt8(instanceOffset), 0, 16, 0x80, 1, 0, 0, 0, 120, 0, UInt8(entries.count)] + entries
        // A: host → 192.168.1.50
        data += [0xC0, UInt8(hostOffset), 0, 1, 0x80, 1, 0, 0, 0, 120, 0, 4, 192, 168, 1, 50]
        return data
    }

    @Test func readsAChromecastAnswer() throws {
        let records = MDNS.parse(response())
        #expect(records.count == 4)
        let services = MDNS.services(of: "_googlecast._tcp.local", in: records)
        let service = try #require(services.first)
        #expect(service.txt["fn"] == "Gym TV")
        #expect(service.txt["md"] == "Chromecast")
        #expect(service.address == "192.168.1.50")
        #expect(service.port == 8009)
    }

    @Test func questionIsAPTRQuery() {
        let question = MDNS.question("_googlecast._tcp.local")
        #expect(question.prefix(6) == Data([0, 0, 0, 0, 0, 1]))
        #expect(question.suffix(4) == Data([0, 12, 0, 1]))
    }

    @Test func ignoresTruncatedPackets() {
        #expect(MDNS.parse(Data([0, 0, 0x84, 0, 0, 0, 0, 5])).isEmpty)
        #expect(MDNS.parse(response().prefix(40)).count < 4)
    }
}
