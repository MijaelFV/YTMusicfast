import Foundation

/// A Google Cast (CASTV2) message: the `CastMessage` protobuf every Cast device speaks, sent as a
/// 4-byte big-endian length followed by the encoded message. Only text payloads are used (JSON).
struct CastMessage: Equatable, Sendable {
    var sourceId: String
    var destinationId: String
    var namespace: String
    var payload: String

    /// The bytes to send: length prefix and message.
    func framed() -> Data {
        var body = Data()
        // 1: protocol_version = CASTV2_1_0 (0)
        body.append(contentsOf: [0x08, 0x00])
        Self.appendString(2, sourceId, to: &body)
        Self.appendString(3, destinationId, to: &body)
        Self.appendString(4, namespace, to: &body)
        // 5: payload_type = STRING (0)
        body.append(contentsOf: [0x28, 0x00])
        Self.appendString(6, payload, to: &body)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Reads one message body (without its length prefix). Nil for anything malformed.
    static func decode(_ body: Data) -> CastMessage? {
        var message = CastMessage(sourceId: "", destinationId: "", namespace: "", payload: "")
        var index = body.startIndex
        while index < body.endIndex {
            guard let key = readVarint(body, &index) else { return nil }
            let field = key >> 3
            switch key & 7 {
            case 0:
                guard readVarint(body, &index) != nil else { return nil }
            case 2:
                guard let length = readVarint(body, &index), length <= UInt64(body.endIndex - index) else { return nil }
                let end = index + Int(length)
                let bytes = body[index..<end]
                index = end
                let text = String(decoding: bytes, as: UTF8.self)
                switch field {
                case 2: message.sourceId = text
                case 3: message.destinationId = text
                case 4: message.namespace = text
                case 6: message.payload = text
                default: break
                }
            default:
                return nil
            }
        }
        return message
    }

    private static func appendString(_ field: UInt64, _ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendVarint(field << 3 | 2, to: &data)
        appendVarint(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
    }

    private static func readVarint(_ data: Data, _ index: inout Data.Index) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}

/// HTTP byte ranges ("bytes=100-", "bytes=0-1023") as the Cast receiver asks for them.
enum ByteRange {
    /// The first and last byte to send for a `Range` header value, within `length` bytes;
    /// `limit` caps how much one response carries. Nil when the range can't be satisfied.
    static func parse(_ header: String?, length: Int, limit: Int) -> ClosedRange<Int>? {
        guard length > 0 else { return nil }
        var start = 0
        var end = length - 1
        if let header, header.hasPrefix("bytes=") {
            let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return nil }
            if parts[0].isEmpty {
                // "bytes=-500": the last 500 bytes.
                guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
                start = max(0, length - suffix)
            } else {
                guard let first = Int(parts[0]) else { return nil }
                start = first
                if let last = Int(parts[1]) { end = min(last, length - 1) }
            }
        }
        guard start < length, start <= end, limit > 0 else { return nil }
        // With no real limit (Int.max), start + limit overflows: then the range's own end applies.
        let (capped, overflow) = start.addingReportingOverflow(limit - 1)
        return start...(overflow ? end : min(end, capped))
    }
}
