import Foundation

// `ytmusicfast`: controls the running YT Musicfast from the terminal, scripts and launchers
// (Raycast, Alfred, Stream Deck). Talks to the app over a per-user Mach message port.
//
//   ytmusicfast play-pause | play | pause | next | previous
//   ytmusicfast volume [N] | volume-up [N] | volume-down [N] | mute
//   ytmusicfast shuffle [on|off] | repeat [off|all|one]
//   ytmusicfast seek N | seek -- -N | seek-to N
//   ytmusicfast like
//   ytmusicfast play-search [--kind song|album|artist|playlist] words…
//   ytmusicfast now-playing [--raw] | devices [--raw] | transfer <device-id|default>
//   ytmusicfast show | open <link> | <link>
//   ytmusicfast diagnose [link|id] [--video [--quality N] [--at SECONDS]]
//
// Commands print nothing on success unless they report something; the exit status is 1 when the
// command failed and 2 when YT Musicfast isn't running.

let help = """
usage: ytmusicfast <command> [arguments]

Playback      play-pause, play, pause, next, previous
Volume        volume [0-100], volume-up [N], volume-down [N], mute
Modes         shuffle [on|off], repeat [off|all|one]
Position      seek <seconds> (seek -- -10 goes back), seek-to <seconds>
Library       like (toggle the playing song)
Play          play-search [--kind song|album|artist|playlist] <words>
Status        now-playing [--raw], devices [--raw], transfer <device-id|default>
App           show, open <link>, <link>
Support       diagnose [song link or id] (which audio YouTube offers, and whether it downloads)
              diagnose <id> --video [--quality 720] [--at 60] (its music video: sizes, start time, frames)

--raw now-playing prints tab-separated: state, title, artists, album, position, duration,
volume, shuffle, repeat, artwork URL, saved, device.
"""

struct Request: Codable {
    var args: [String]
    var replyPort: String
}

struct Reply: Codable {
    var output: String
    var status: Int32
}

var args = Array(CommandLine.arguments.dropFirst())
// "seek -- -10": the separator only keeps the shell-style negative number from looking like a flag.
args.removeAll { $0 == "--" }

if args.isEmpty || ["help", "-h", "--help"].contains(args[0]) {
    print(help)
    exit(args.isEmpty ? 1 : 0)
}

/// Starts the app (for `show` and links), waiting until it answers.
func launchApp() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", "-b", "dev.ytmusicfast.app"]
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    for _ in 0..<50 {
        if CFMessagePortCreateRemote(nil, "dev.ytmusicfast.app.control" as CFString) != nil { return true }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return false
}

var remote = CFMessagePortCreateRemote(nil, "dev.ytmusicfast.app.control" as CFString)
if remote == nil {
    let startsApp = args[0] == "show" || args[0] == "open" || args[0].contains("://")
    guard startsApp, launchApp() else {
        FileHandle.standardError.write(Data("YT Musicfast isn't running.\n".utf8))
        exit(2)
    }
    remote = CFMessagePortCreateRemote(nil, "dev.ytmusicfast.app.control" as CFString)
}

// Our own port for the answer.
final class ReplyBox { var reply: Reply? }
let box = ReplyBox()
let replyName = "dev.ytmusicfast.cli.\(getpid())"
var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil)
var shouldFree: DarwinBoolean = false
guard let local = CFMessagePortCreateLocal(nil, replyName as CFString, { _, _, data, info in
    if let info, let data = data as Data? {
        Unmanaged<ReplyBox>.fromOpaque(info).takeUnretainedValue().reply = try? JSONDecoder().decode(Reply.self, from: data)
    }
    CFRunLoopStop(CFRunLoopGetCurrent())
    return nil
}, &context, &shouldFree) else {
    FileHandle.standardError.write(Data("Couldn't open a reply channel.\n".utf8))
    exit(1)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMessagePortCreateRunLoopSource(nil, local, 0), .defaultMode)

guard let remote, let body = try? JSONEncoder().encode(Request(args: args, replyPort: replyName)),
      CFMessagePortSendRequest(remote, 0, body as CFData, 5, 0, nil, nil) == kCFMessagePortSuccess else {
    FileHandle.standardError.write(Data("YT Musicfast didn't answer.\n".utf8))
    exit(2)
}

// Searches can take a few seconds.
let result = CFRunLoopRunInMode(.defaultMode, args[0] == "diagnose" ? 90 : 20, false)
CFMessagePortInvalidate(local)
guard let reply = box.reply else {
    FileHandle.standardError.write(Data(result == .timedOut ? "Timed out waiting for YT Musicfast.\n".utf8 : "No answer.\n".utf8))
    exit(1)
}
if !reply.output.isEmpty {
    if reply.status == 0 { print(reply.output) } else { FileHandle.standardError.write(Data((reply.output + "\n").utf8)) }
}
exit(reply.status)
