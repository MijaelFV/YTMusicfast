import Foundation

/// Lightweight, forgiving view over decoded JSON.
///
/// InnerTube responses are huge, deeply nested and change shape often, so instead of
/// strict `Codable` models we navigate them dynamically and fall back gracefully.
struct JSON: @unchecked Sendable {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    init(data: Data) throws {
        raw = try JSONSerialization.jsonObject(with: data)
    }

    static let null = JSON(nil)

    subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSON {
        guard let array = raw as? [Any], array.indices.contains(index) else { return .null }
        return JSON(array[index])
    }

    /// Follows a dotted path, e.g. `json["a.b.0.c"]`-style but explicit: `json.at("a", "b", 0, "c")`.
    func at(_ path: Any...) -> JSON {
        var current = self
        for component in path {
            if let key = component as? String {
                current = current[key]
            } else if let index = component as? Int {
                current = current[index]
            }
        }
        return current
    }

    var exists: Bool { raw != nil && !(raw is NSNull) }
    var string: String? { raw as? String }
    var bool: Bool? { raw as? Bool }

    var int: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }

    var dictionary: [String: JSON] {
        (raw as? [String: Any])?.mapValues(JSON.init) ?? [:]
    }

    var keys: [String] { (raw as? [String: Any]).map { Array($0.keys) } ?? [] }

    /// First key of an object — renderer wrappers are single-key objects like `{"musicShelfRenderer": {...}}`.
    var firstKey: String? { keys.first }

    // MARK: Text helpers

    var runs: [JSON] { self["runs"].array }

    /// Joined text of a `{runs: [...]}` or `{simpleText: ...}` object.
    var text: String? {
        if let simple = self["simpleText"].string { return simple }
        let parts = runs.compactMap { $0["text"].string }
        return parts.isEmpty ? nil : parts.joined()
    }

    // MARK: Tree search

    /// Depth-first search for every value stored under `key`, in document order
    /// (arrays keep order; object keys are visited in a stable priority order).
    func findAll(_ key: String, limit: Int = .max) -> [JSON] {
        var results: [JSON] = []
        JSON.collect(raw, key: key, into: &results, limit: limit, descendIntoMatches: false)
        return results
    }

    func first(_ key: String) -> JSON? {
        findAll(key, limit: 1).first
    }

    private static let keyPriority = ["header", "tabs", "contents", "content", "secondaryContents", "continuationContents"]

    static func orderedKeys(_ dict: [String: Any]) -> [String] {
        dict.keys.sorted { a, b in
            let ia = keyPriority.firstIndex(of: a) ?? Int.max
            let ib = keyPriority.firstIndex(of: b) ?? Int.max
            return ia == ib ? a < b : ia < ib
        }
    }

    private static func collect(_ node: Any?, key: String, into results: inout [JSON], limit: Int, descendIntoMatches: Bool) {
        guard results.count < limit else { return }
        if let dict = node as? [String: Any] {
            for k in orderedKeys(dict) {
                guard results.count < limit else { return }
                let value = dict[k]
                if k == key {
                    results.append(JSON(value))
                    if !descendIntoMatches { continue }
                }
                collect(value, key: key, into: &results, limit: limit, descendIntoMatches: descendIntoMatches)
            }
        } else if let array = node as? [Any] {
            for value in array {
                guard results.count < limit else { return }
                collect(value, key: key, into: &results, limit: limit, descendIntoMatches: descendIntoMatches)
            }
        }
    }
}
