import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import Network
import Observation

/// Control YTMusicfast from your phone: a small web page served on your
/// Wi‑Fi. Open the address (or scan the QR code) on any phone browser; a PIN keeps others out.
@MainActor
@Observable
final class PhoneRemote {
    static let shared = PhoneRemote()
    static let port: UInt16 = 51_234

    var enabled = UserDefaults.standard.bool(forKey: "phoneRemote") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "phoneRemote")
            enabled ? start() : stop()
        }
    }

    /// Six digits the page asks for once (a 4-digit one from an older version is replaced).
    private(set) var pin = UserDefaults.standard.string(forKey: "phoneRemotePIN").flatMap { $0.count >= 6 ? $0 : nil } ?? PhoneRemote.newPIN()
    private(set) var running = false
    private(set) var lastError: String?

    @ObservationIgnored private var listener: NWListener?
    /// Wrong PINs in a row; after ten, the remote pauses for a minute (a million codes, ten a minute).
    @ObservationIgnored private var wrongPins = 0
    @ObservationIgnored private var lockedUntil = Date.distantPast

    private static func newPIN() -> String {
        let pin = String(format: "%06d", Int.random(in: 0...999_999))
        UserDefaults.standard.set(pin, forKey: "phoneRemotePIN")
        return pin
    }

    private init() {}

    func startIfEnabled() { if enabled { start() } }

    func newCode() {
        pin = Self.newPIN()
    }

    /// The address to open on the phone (this Mac's Wi‑Fi address).
    var address: String? {
        Self.localIPv4().map { "http://\($0):\(Self.port)/?pin=\(pin)" }
    }

    // MARK: Server

    private func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { connection in
                Task { @MainActor in PhoneRemote.shared.handle(connection) }
            }
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready: PhoneRemote.shared.running = true; PhoneRemote.shared.lastError = nil
                    case .failed(let error): PhoneRemote.shared.running = false; PhoneRemote.shared.lastError = error.localizedDescription
                    case .cancelled: PhoneRemote.shared.running = false
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            Task { @MainActor in
                let response = PhoneRemote.shared.respond(to: data.map { String(decoding: $0, as: UTF8.self) } ?? "")
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func respond(to request: String) -> Data {
        let line = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let url = URLComponents(string: String(parts[1])) else { return Self.http(400, "text/plain", "Bad request") }
        let path = url.path
        if path == "/" || path == "/index.html" { return Self.http(200, "text/html; charset=utf-8", Self.page) }
        guard Date() >= lockedUntil else { return Self.http(403, "text/plain", "Too many tries — wait a minute") }
        guard url.queryItems?.first(where: { $0.name == "pin" })?.value == pin else {
            wrongPins += 1
            if wrongPins >= 10 { lockedUntil = Date().addingTimeInterval(60); wrongPins = 0 }
            return Self.http(403, "text/plain", "Wrong PIN")
        }
        wrongPins = 0
        let player = PlayerController.shared
        switch path {
        case "/api/state":
            break
        case "/api/toggle": player.togglePlayPause()
        case "/api/next": player.next()
        case "/api/previous": player.previous()
        case "/api/like": player.toggleLike()
        case "/api/shuffle": player.toggleShuffle()
        case "/api/repeat": player.cycleRepeat()
        case "/api/volume":
            if let value = url.queryItems?.first(where: { $0.name == "v" })?.value.flatMap(Double.init) { player.volume = min(1, max(0, value)) }
        case "/api/seek":
            if let value = url.queryItems?.first(where: { $0.name == "t" })?.value.flatMap(Double.init) { player.seek(to: value) }
        case "/api/jump":
            if let id = url.queryItems?.first(where: { $0.name == "id" })?.value, let entry = player.upNext.first(where: { $0.id.uuidString == id }) {
                player.jump(to: entry)
            }
        default:
            return Self.http(404, "text/plain", "Not found")
        }
        return Self.http(200, "application/json", stateJSON())
    }

    private func stateJSON() -> String {
        let player = PlayerController.shared
        var state: [String: Any] = [
            "playing": player.isPlaying, "position": player.playbackPosition, "duration": player.duration,
            "volume": player.volume, "liked": player.likeStatus == .like, "shuffle": player.shuffle,
            "repeat": player.repeatMode.rawValue,
        ]
        if let track = player.current {
            state["title"] = track.title
            state["artist"] = track.artistLine
            state["art"] = Artwork.url(track.thumbnail, size: 300)?.absoluteString ?? ""
        }
        state["upNext"] = player.upNext.prefix(15).map { ["id": $0.id.uuidString, "title": $0.track.title, "artist": $0.track.artistLine] }
        let data = (try? JSONSerialization.data(withJSONObject: state)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func http(_ status: Int, _ type: String, _ body: String) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found"][status] ?? "OK"
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + bytes
    }

    // MARK: Helpers

    /// This Mac's IPv4 address on Wi‑Fi or Ethernet.
    nonisolated static func localIPv4() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidates: [(name: String, address: String)] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            candidates.append((String(cString: interface.pointee.ifa_name), String(cString: host)))
        }
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.address
    }

    /// A QR code of the address, for the phone's camera.
    func qrCode() -> NSImage? {
        guard let address else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(address.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: The page

    private static let page = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <meta name="theme-color" content="#121212"><title>YTMusicfast Remote</title>
    <style>
    :root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;font-family:-apple-system,system-ui,sans-serif;background:#121212;color:#fff;padding:20px 16px env(safe-area-inset-bottom)}
    img{width:100%;max-width:340px;aspect-ratio:1;object-fit:cover;border-radius:10px;display:block;margin:8px auto 18px;background:#282828}
    h1{font-size:22px;margin:0 0 4px}p{margin:0;color:#b3b3b3}.row{display:flex;justify-content:space-between;align-items:center;margin:18px 0}
    button{background:none;border:0;color:#fff;font-size:26px;padding:10px;border-radius:50%}button.main{background:#fff;color:#000;width:68px;height:68px;font-size:30px}
    button.on{color:#ff2c55}input[type=range]{width:100%;accent-color:#ff2c55}.time{display:flex;justify-content:space-between;font-size:12px;color:#b3b3b3}
    li{list-style:none;padding:10px 0;border-bottom:1px solid #282828}ul{padding:0}li small{display:block;color:#b3b3b3}h2{font-size:16px;margin-top:26px}
    #pin{display:none;text-align:center;margin-top:30vh}#pin input{font-size:28px;width:140px;text-align:center;border-radius:8px;border:0;padding:8px}
    </style></head><body>
    <div id="pin"><p>Enter the PIN shown in YT Musicfast → Settings</p><br><input id="p" inputmode="numeric" maxlength="6"><br><br><button class="main" onclick="savePin()">→</button></div>
    <div id="app"><img id="art" alt=""><h1 id="t">Nothing playing</h1><p id="a"></p>
    <input id="seek" type="range" min="0" max="1" step="1" onchange="api('seek','&t='+this.value)"><div class="time"><span id="cur">0:00</span><span id="dur">0:00</span></div>
    <div class="row"><button id="sh" onclick="api('shuffle')">⤨</button><button onclick="api('previous')">⏮</button><button class="main" id="pp" onclick="api('toggle')">▶</button><button onclick="api('next')">⏭</button><button id="rp" onclick="api('repeat')">↻</button></div>
    <div class="row"><span>🔈</span><input id="vol" type="range" min="0" max="1" step="0.02" oninput="api('volume','&v='+this.value)"><button id="lk" onclick="api('like')">♡</button></div>
    <h2>Up next</h2><ul id="q"></ul></div>
    <script>
    let pin=new URLSearchParams(location.search).get('pin')||localStorage.getItem('pin');if(pin)localStorage.setItem('pin',pin);
    function savePin(){pin=document.getElementById('p').value;localStorage.setItem('pin',pin);show();refresh()}
    function show(){document.getElementById('pin').style.display=pin?'none':'block';document.getElementById('app').style.display=pin?'block':'none'}
    function fmt(s){s=Math.max(0,Math.floor(s||0));return Math.floor(s/60)+':'+String(s%60).padStart(2,'0')}
    async function api(cmd,extra){try{const r=await fetch('/api/'+cmd+'?pin='+pin+(extra||''));if(r.status==403){pin=null;localStorage.removeItem('pin');show();return}render(await r.json())}catch(e){}}
    function render(s){const $=id=>document.getElementById(id);$('t').textContent=s.title||'Nothing playing';$('a').textContent=s.artist||'';
    if(s.art&&$('art').src!==s.art)$('art').src=s.art;$('pp').textContent=s.playing?'⏸':'▶';$('lk').textContent=s.liked?'♥':'♡';$('lk').className=s.liked?'on':'';
    $('sh').className=s.shuffle?'on':'';$('rp').className=s.repeat!=='off'?'on':'';$('rp').textContent=s.repeat==='one'?'↻¹':'↻';
    $('seek').max=Math.max(1,Math.floor(s.duration||1));if(document.activeElement!==$('seek'))$('seek').value=Math.floor(s.position||0);
    $('cur').textContent=fmt(s.position);$('dur').textContent=fmt(s.duration);if(document.activeElement!==$('vol'))$('vol').value=s.volume;
    $('q').innerHTML='';(s.upNext||[]).forEach(e=>{const li=document.createElement('li');li.textContent=e.title;const sm=document.createElement('small');sm.textContent=e.artist;li.appendChild(sm);li.onclick=()=>api('jump','&id='+e.id);$('q').appendChild(li)})}
    function refresh(){if(pin)api('state')}show();refresh();setInterval(refresh,1500);
    </script></body></html>
    """
}
