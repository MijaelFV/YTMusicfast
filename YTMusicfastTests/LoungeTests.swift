import Foundation
import Testing

@Suite("YouTube TV lounge protocol")
struct LoungeTests {
    private func reader(_ text: String) -> [Lounge.Event] {
        var reader = Lounge.ChunkReader()
        return reader.append(Data(text.utf8))
    }

    @Test func bindAnswerGivesTheSession() throws {
        let chunk = #"[[0,["c","8A1D2F","",8]],[1,["S","1B2C3D"]],[2,["loungeStatus",{"devices":"[{\"app\":\"lb-v4\"}]","connectionEventDetails":"{}"}]]]"#
        let events = reader("\(chunk.utf16.count)\n\(chunk)")
        #expect(events.map(\.name) == ["c", "S", "loungeStatus"])
        let session = try #require(Lounge.session(in: events))
        #expect(session.sid == "8A1D2F")
        #expect(session.gsessionId == "1B2C3D")
        // A nested JSON string stays the string it was.
        #expect(events[2].fields["devices"] == #"[{"app":"lb-v4"}]"#)
    }

    /// A real bind answer (2026-10-15): elements on their own lines inside the chunk.
    @Test func realBindAnswer() throws {
        let answer = """
        656
        [[0,["c","E98942650B592E95","",8]]
        ,[1,["S","LsphSpD5C2xEPowBvIzpJQr-6iM6SSm0Q3fjrn_wXHA"]]
        ,[2,["loungeStatus",{"queueId":"RQPjbo5E","devices":"[{\\"app\\":\\"ytmusicfast\\",\\"name\\":\\"YT Musicfast\\"}]"}]]
        ,[3,["onAutoplayModeChanged",{"autoplayMode":"UNSUPPORTED"}]]
        ,[4,["onPlaylistModeChanged",{"shuffleEnabled":"false","loopEnabled":"false"}]]
        ]

        """
        let events = reader(answer)
        #expect(events.map(\.id) == [0, 1, 2, 3, 4])
        let session = try #require(Lounge.session(in: events))
        #expect(session.sid == "E98942650B592E95")
        #expect(events[3].fields["autoplayMode"] == "UNSUPPORTED")
    }

    @Test func noSessionWithoutBothIds() {
        #expect(Lounge.session(in: reader(#"20\#n[[0,["c","","",8]]]"#)) == nil)
        #expect(Lounge.session(in: [Lounge.Event(id: 0, name: "c", fields: ["0": "x"])]) == nil)
    }

    /// The long poll's bytes arrive in any split: events come out once their chunk is whole.
    @Test func chunksSplitAnywhere() {
        let first = #"[[3,["onStateChange",{"currentTime":"12.5","state":"1","duration":"201.3","cpn":"x]y[z"}]]]"#
        let second = #"[[4,["noop"]],[5,["nowPlaying",{"videoId":"dQw4w9WgXcQ","currentTime":"0","state":"3"}]]]"#
        let stream = Data("\(first.utf16.count)\n\(first)\n\(second.utf16.count)\n\(second)\n".utf8)
        var reader = Lounge.ChunkReader()
        var events: [Lounge.Event] = []
        for byte in stream { events += reader.append(byte) }
        #expect(events.map(\.id) == [3, 4, 5])
        #expect(events.map(\.name) == ["onStateChange", "noop", "nowPlaying"])

        // Split in two halves, the second starting mid-string.
        var halves = Lounge.ChunkReader()
        let middle = stream.count / 3
        #expect(halves.append(stream.prefix(middle)).isEmpty)
        #expect(halves.append(stream.dropFirst(middle)).map(\.id) == [3, 4, 5])
    }

    /// Lengths count UTF-16 units; titles with accents or emoji mustn't throw the reader off.
    @Test func multibyteTextAndEscapes() {
        let chunk = #"[[7,["nowPlaying",{"videoId":"abc","title":"Canción \"🎵\" ]["}]],[8,["onVolumeChanged",{"volume":"40","muted":"false"}]]]"#
        let events = reader("\(chunk.utf16.count)\n\(chunk)")
        #expect(events.count == 2)
        #expect(events[0].fields["title"] == "Canción \"🎵\" ][")
        #expect(events[1].fields["volume"] == "40")
    }

    @Test func junkBetweenChunksIsSkipped() {
        let events = reader(")]}'\n" + #"16\#n[[1,["S","abc"]]]"# + "garbage\n" + #"12\#n[[2,["noop"]]]"#)
        #expect(events.map(\.id) == [1, 2])
    }

    @Test func positionalArgumentsAndNumbers() throws {
        let events = reader(#"30\#n[[9,["c","SID",true,8,null,1.5]]]"#)
        let event = try #require(events.first)
        #expect(event.fields == ["0": "SID", "1": "true", "2": "8", "3": "", "4": "1.5"])
    }

    @Test func playbackFromStateChange() throws {
        let event = Lounge.Event(id: 1, name: "onStateChange", fields: ["currentTime": "12.5", "state": "2", "duration": "201.3"])
        let playback = try #require(Lounge.Playback(event))
        #expect(playback == Lounge.Playback(videoId: nil, state: .paused, currentTime: 12.5, duration: 201.3))
    }

    @Test func playbackFromNowPlaying() throws {
        let playing = try #require(Lounge.Playback(Lounge.Event(id: 2, name: "nowPlaying", fields: ["videoId": "abc", "currentTime": "3", "state": "1"])))
        #expect(playing.videoId == "abc")
        #expect(playing.state == .playing)
        // An empty nowPlaying: nothing loaded on the TV.
        let empty = try #require(Lounge.Playback(Lounge.Event(id: 3, name: "nowPlaying")))
        #expect(empty.videoId == nil)
        #expect(empty.state == nil)
        #expect(Lounge.Playback(Lounge.Event(id: 4, name: "onVolumeChanged")) == nil)
    }

    @Test func playbackStates() {
        #expect(Lounge.Playback.State(-1) == .unstarted)
        #expect(Lounge.Playback.State(0) == .ended)
        #expect(Lounge.Playback.State(1) == .playing)
        #expect(Lounge.Playback.State(3) == .buffering)
        #expect(Lounge.Playback.State(5) == .cued)
        #expect(Lounge.Playback.State(1081) == .advertisement)
        #expect(Lounge.Playback.State(42) == .unknown(42))
    }

    @Test func badNumbersAreDropped() throws {
        let playback = try #require(Lounge.Playback(Lounge.Event(id: 1, name: "onStateChange", fields: ["currentTime": "nan", "duration": "0", "state": "x"])))
        #expect(playback.currentTime == nil)
        #expect(playback.duration == nil)
        #expect(playback.state == nil)
    }

    @Test func commandForms() {
        func body(_ command: Lounge.Command, _ offset: Int = 0) -> String {
            String(decoding: Lounge.form(Lounge.commandForm(command, offset: offset)), as: UTF8.self)
        }
        #expect(body(.play, 3) == "count=1&ofs=3&req0__sc=play")
        #expect(body(.pause) == "count=1&ofs=0&req0__sc=pause")
        #expect(body(.seek(42.25)) == "count=1&ofs=0&req0__sc=seekTo&req0_newTime=42.250")
        #expect(body(.seek(.nan)) == "count=1&ofs=0&req0__sc=seekTo&req0_newTime=0.000")
        #expect(body(.setVolume(140)) == "count=1&ofs=0&req0__sc=setVolume&req0_volume=100")
        #expect(body(.insertVideo("abc")) == "count=1&ofs=0&req0__sc=insertVideo&req0_videoId=abc")
        #expect(body(.removeVideo("abc")) == "count=1&ofs=0&req0__sc=removeVideo&req0_videoId=abc")
        #expect(body(.setAutoplay(false)) == "count=1&ofs=0&req0__sc=setAutoplayMode&req0_autoplayMode=DISABLED")
        #expect(body(.setPlaylist(videoIds: ["a-1", "b_2"], index: 1, time: 5))
            == "count=1&ofs=0&req0__sc=setPlaylist&req0_videoId=b_2&req0_videoIds=a-1%2Cb_2&req0_currentIndex=1&req0_currentTime=5.000&req0_listId=&req0_audioOnly=false")
        // An index past the list plays its first.
        #expect(body(.setPlaylist(videoIds: ["a"], index: 4, time: 0)).contains("req0_videoId=a&"))
    }

    @Test func followingTheTV() {
        let sent = ["a", "b", "c", "d"]
        // The next one, or several on (the TV went on while this Mac slept).
        #expect(Lounge.songsAhead(to: "b", sent: sent, upNext: ["b", "c", "d"]) == 1)
        #expect(Lounge.songsAhead(to: "d", sent: sent, upNext: ["b", "c", "d", "e"]) == 3)
        // A song put next here since: the TV's list is out of date.
        #expect(Lounge.songsAhead(to: "b", sent: sent, upNext: ["x", "b", "c"]) == nil)
        // Not from the list (picked on the TV, or its own autoplay), or still the same song.
        #expect(Lounge.songsAhead(to: "z", sent: sent, upNext: ["b", "c"]) == nil)
        #expect(Lounge.songsAhead(to: "a", sent: sent, upNext: ["b", "c"]) == nil)
        #expect(Lounge.songsAhead(to: "b", sent: ["a"], upNext: ["b"]) == nil)
        #expect(Lounge.songsAhead(to: "c", sent: sent, upNext: ["b"]) == nil)
    }

    @Test func formEscaping() {
        #expect(Lounge.formString([("name", "YT Musicfast"), ("x", "a+b/c=d&e")]) == "name=YT%20Musicfast&x=a%2Bb%2Fc%3Dd%26e")
        #expect(Lounge.formString([("ui", "")]) == "ui=")
    }

    @Test func bindFormIsARemote() {
        let form = Dictionary(uniqueKeysWithValues: Lounge.bindForm(remoteId: "r1"))
        #expect(form["device"] == "REMOTE_CONTROL")
        #expect(form["id"] == "r1")
        #expect(form["mdx-version"] == "3")
    }

    @Test func screenIdFromTheTVApp() {
        #expect(Lounge.screenId(inMdxMessage: ["type": "mdxSessionStatus", "data": ["screenId": "s123", "deviceId": "d"]]) == "s123")
        #expect(Lounge.screenId(inMdxMessage: ["type": "mdxSessionStatus", "data": ["screenId": ""]]) == nil)
        #expect(Lounge.screenId(inMdxMessage: ["type": "other", "data": ["screenId": "s"]]) == nil)
    }

    @Test func loungeToken() throws {
        let data = Data(#"{"screens":[{"screenId":"other","loungeToken":"t0"},{"screenId":"s123","loungeToken":"AGdO5p-x_y","expiration":1760000000000}]}"#.utf8)
        let answer = try #require(Lounge.loungeToken(in: data, screenId: "s123"))
        #expect(answer.token == "AGdO5p-x_y")
        #expect(answer.expires == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(Lounge.loungeToken(in: Data(#"{"screens":[]}"#.utf8), screenId: "s") == nil)
        #expect(Lounge.loungeToken(in: Data("not json".utf8), screenId: "s") == nil)
    }
}
