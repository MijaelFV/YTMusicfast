import Darwin
import Foundation

/// A tiny multicast DNS (Bonjour) client: asks the local network once for a service type and reads
/// the answers itself. macOS's own Bonjour service checks the asking app's Info.plist, which it
/// can't read for an app kept in the home folder (it then refuses as if the type weren't
/// declared); asking directly works wherever the app lives. Still subject to the user's Local
/// Network permission.
enum MDNS {
    /// One service instance from the answers: where it is and its TXT record.
    struct Service: Equatable, Sendable {
        var instance: String
        var host: String
        var port: UInt16
        var address: String
        var txt: [String: String]
    }

    /// Sends a question for `type` (e.g. "_googlecast._tcp.local") and collects answers for
    /// `timeout` seconds. Nil when the question can't be sent at all — which is how macOS says
    /// the app hasn't been allowed on the local network. Blocking: call off the main thread.
    static func browse(_ type: String, timeout: TimeInterval = 1.5) -> [Service]? {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { return nil }
        defer { close(socket) }
        var ttl: UInt8 = 255
        setsockopt(socket, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var wait = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        // From an ordinary port, responders answer us directly (RFC 6762 §6.7 "legacy unicast").
        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(5353).bigEndian
        destination.sin_addr.s_addr = inet_addr("224.0.0.251")
        let query = question(type)
        func ask() -> Bool {
            let sent = query.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(socket, bytes.baseAddress, query.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            return sent == query.count
        }
        guard ask() else { return nil }

        var records: [Record] = []
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        // Asked again a little later: a device that was busy or asleep often misses the first.
        var repeats = [0.4, 1.0].map { start.addingTimeInterval($0 * timeout / 1.5) }
        var buffer = [UInt8](repeating: 0, count: 9000)
        while Date() < deadline {
            if let next = repeats.first, Date() >= next {
                repeats.removeFirst()
                _ = ask()
            }
            let count = recv(socket, &buffer, buffer.count, 0)
            if count > 0 { records += parse(Data(buffer[0..<count])) }
        }
        return services(of: type, in: records)
    }

    // MARK: Messages

    /// A standard query for the PTR records of a service type.
    static func question(_ type: String) -> Data {
        var data = Data([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0])  // id 0, flags 0, one question
        data += encode(name: type)
        data += [0, 12, 0, 1]  // PTR, IN
        return data
    }

    static func encode(name: String) -> Data {
        var data = Data()
        for label in name.split(separator: ".") where !label.isEmpty {
            let bytes = Data(label.utf8)
            data.append(UInt8(min(bytes.count, 63)))
            data += bytes.prefix(63)
        }
        data.append(0)
        return data
    }

    struct Record: Equatable {
        enum Value: Equatable {
            case pointer(String)
            case service(host: String, port: UInt16)
            case text([String: String])
            case address(String)
            case other
        }
        var name: String
        var value: Value
    }

    /// Every record in a response (answers and additional records alike).
    static func parse(_ data: Data) -> [Record] {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { return [] }
        func u16(_ at: Int) -> Int? { at + 1 < bytes.count ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : nil }
        guard let questions = u16(4), let answers = u16(6), let authorities = u16(8), let additional = u16(10) else { return [] }
        var index = 12
        for _ in 0..<questions {
            guard readName(bytes, &index) != nil else { return [] }
            index += 4
        }
        var records: [Record] = []
        for _ in 0..<(answers + authorities + additional) {
            guard let name = readName(bytes, &index), let type = u16(index), let length = u16(index + 8) else { break }
            let start = index + 10
            let end = start + length
            guard end <= bytes.count else { break }
            var value = Record.Value.other
            switch type {
            case 12:
                var at = start
                if let target = readName(bytes, &at) { value = .pointer(target) }
            case 33:
                if let port = u16(start + 4) {
                    var at = start + 6
                    if let host = readName(bytes, &at) { value = .service(host: host, port: UInt16(port)) }
                }
            case 16:
                var txt: [String: String] = [:]
                var at = start
                while at < end {
                    let count = Int(bytes[at])
                    at += 1
                    guard at + count <= end else { break }
                    let entry = String(decoding: bytes[at..<(at + count)], as: UTF8.self)
                    if let equals = entry.firstIndex(of: "=") {
                        txt[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
                    }
                    at += count
                }
                value = .text(txt)
            case 1 where length == 4:
                value = .address(bytes[start..<end].map(String.init).joined(separator: "."))
            default:
                break
            }
            records.append(Record(name: name, value: value))
            index = end
        }
        return records
    }

    /// Reads a (possibly compressed) domain name; `index` moves past it.
    static func readName(_ bytes: [UInt8], _ index: inout Int) -> String? {
        var labels: [String] = []
        var at = index
        var jumped = false
        var jumps = 0
        while at < bytes.count {
            let length = Int(bytes[at])
            if length == 0 {
                if !jumped { index = at + 1 }
                return labels.joined(separator: ".")
            }
            if length & 0xC0 == 0xC0 {
                guard at + 1 < bytes.count, jumps < 20 else { return nil }
                let pointer = (length & 0x3F) << 8 | Int(bytes[at + 1])
                if !jumped { index = at + 2 }
                jumped = true
                jumps += 1
                at = pointer
                continue
            }
            guard at + 1 + length <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[(at + 1)..<(at + 1 + length)], as: UTF8.self))
            at += 1 + length
        }
        return nil
    }

    /// Puts PTR → SRV → A and TXT records together into services of `type`.
    static func services(of type: String, in records: [Record]) -> [Service] {
        func same(_ a: String, _ b: String) -> Bool { a.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == b.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        let instances = records.compactMap { record -> String? in
            if same(record.name, type), case .pointer(let instance) = record.value { return instance }
            return nil
        }
        var result: [Service] = []
        for instance in Set(instances) {
            guard let (host, port) = records.lazy.compactMap({ record -> (String, UInt16)? in
                if same(record.name, instance), case .service(let host, let port) = record.value { return (host, port) }
                return nil
            }).first,
                let address = records.lazy.compactMap({ record -> String? in
                    if same(record.name, host), case .address(let address) = record.value { return address }
                    return nil
                }).first else { continue }
            let txt = records.lazy.compactMap { record -> [String: String]? in
                if same(record.name, instance), case .text(let txt) = record.value { return txt }
                return nil
            }.first ?? [:]
            result.append(Service(instance: instance, host: host, port: port, address: address, txt: txt))
        }
        return result.sorted { $0.instance < $1.instance }
    }
}
