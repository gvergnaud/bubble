// A JSON encoder that writes keys in the order `encode(to:)` writes them. Owner: E1.
// Foundation's JSONEncoder orders keys at random (or sorted): the API answers then differ from the
// mock and from one request to the next. Here `{"start":…,"end":…,"rate":…}` stays in the
// contract's order, numbers are written like JavaScript writes them (`1`, not `1.0`), `/` is not escaped.
import Foundation

public enum OrderedJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let root = Box()
        try value.encode(to: Writer(box: root, codingPath: []))
        var out = ""
        root.write(to: &out)
        return Data(out.utf8)
    }

    final class Box {
        enum Kind { case empty, raw(String), object([(String, Box)]), array([Box]) }
        var kind: Kind = .empty

        func write(to out: inout String) {
            switch kind {
            case .empty: out += "{}"
            case .raw(let s): out += s
            case .object(let pairs):
                out += "{"
                for (i, (k, v)) in pairs.enumerated() {
                    if i > 0 { out += "," }
                    out += OrderedJSON.string(k); out += ":"
                    v.write(to: &out)
                }
                out += "}"
            case .array(let items):
                out += "["
                for (i, v) in items.enumerated() { if i > 0 { out += "," }; v.write(to: &out) }
                out += "]"
            }
        }

        func child(forKey key: String) -> Box {
            if case .object(var pairs) = kind {
                let b = Box()
                if let i = pairs.firstIndex(where: { $0.0 == key }) { pairs[i].1 = b } else { pairs.append((key, b)) }
                kind = .object(pairs)
                return b
            }
            kind = .object([])
            return child(forKey: key)
        }

        func appendChild() -> Box {
            let b = Box()
            if case .array(var items) = kind { items.append(b); kind = .array(items) } else { kind = .array([b]) }
            return b
        }

        var count: Int { if case .array(let a) = kind { a.count } else { 0 } }
    }

    static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20 || u.value == 0x2028 || u.value == 0x2029:
                out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    /// Like JavaScript's `String(n)` for the numbers we send: integers without `.0`, else the
    /// shortest round-tripping form. NaN and ±∞ (never valid here) become null.
    static func number(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }

    struct Writer: Encoder {
        let box: Box
        var codingPath: [CodingKey]
        var userInfo: [CodingUserInfoKey: Any] { [:] }

        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            if case .object = box.kind {} else { box.kind = .object([]) }
            return KeyedEncodingContainer(Keyed<Key>(box: box, codingPath: codingPath))
        }
        func unkeyedContainer() -> UnkeyedEncodingContainer {
            if case .array = box.kind {} else { box.kind = .array([]) }
            return Unkeyed(box: box, codingPath: codingPath)
        }
        func singleValueContainer() -> SingleValueEncodingContainer { Single(box: box, codingPath: codingPath) }
    }

    struct Single: SingleValueEncodingContainer {
        let box: Box
        var codingPath: [CodingKey]
        mutating func encodeNil() throws { box.kind = .raw("null") }
        mutating func encode(_ v: Bool) throws { box.kind = .raw(v ? "true" : "false") }
        mutating func encode(_ v: String) throws { box.kind = .raw(OrderedJSON.string(v)) }
        mutating func encode(_ v: Double) throws { box.kind = .raw(OrderedJSON.number(v)) }
        mutating func encode(_ v: Float) throws { box.kind = .raw(OrderedJSON.number(Double(v))) }
        mutating func encode(_ v: Int) throws { box.kind = .raw(String(v)) }
        mutating func encode(_ v: Int8) throws { box.kind = .raw(String(v)) }
        mutating func encode(_ v: Int16) throws { box.kind = .raw(String(v)) }
        mutating func encode(_ v: Int32) throws { box.kind = .raw(String(v)) }
        mutating func encode(_ v: Int64) throws { box.kind = .raw(String(v)) }
        mutating func encode(_ v: UInt) throws { box.kind = .raw(String(v)) }
        mutating func encode(_ v: UInt8) throws { box.kind = .raw(String(v)) }
        mutating func encode(_ v: UInt16) throws { box.kind = .raw(String(v)) }
        mutating func encode(_ v: UInt32) throws { box.kind = .raw(String(v)) }
        mutating func encode(_ v: UInt64) throws { box.kind = .raw(String(v)) }
        mutating func encode<T: Encodable>(_ v: T) throws {
            switch v {
            case let s as String: try encode(s)
            case let d as Double: try encode(d)
            case let b as Bool: try encode(b)
            case let i as Int: try encode(i)
            case let u as URL: try encode(u.absoluteString)
            default: try v.encode(to: Writer(box: box, codingPath: codingPath))
            }
        }
    }

    struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let box: Box
        var codingPath: [CodingKey]
        func single(_ key: Key) -> Single { Single(box: box.child(forKey: key.stringValue), codingPath: codingPath + [key]) }
        mutating func encodeNil(forKey key: Key) throws { var s = single(key); try s.encodeNil() }
        mutating func encode(_ v: Bool, forKey key: Key) throws { var s = single(key); try s.encode(v) }
        mutating func encode(_ v: String, forKey key: Key) throws { var s = single(key); try s.encode(v) }
        mutating func encode(_ v: Double, forKey key: Key) throws { var s = single(key); try s.encode(v) }
        mutating func encode(_ v: Float, forKey key: Key) throws { var s = single(key); try s.encode(v) }
        mutating func encode(_ v: Int, forKey key: Key) throws { var s = single(key); try s.encode(v) }
        mutating func encode(_ v: Int8, forKey key: Key) throws { var s = single(key); try s.encode(v) }
        mutating func encode(_ v: Int16, forKey key: Key) throws { var s = single(key); try s.encode(v) }
        mutating func encode(_ v: Int32, forKey key: Key) throws { var s = single(key); try s.encode(v) }
        mutating func encode(_ v: Int64, forKey key: Key) throws { var s = single(key); try s.encode(v) }
        mutating func encode(_ v: UInt, forKey key: Key) throws { var s = single(key); try s.encode(v) }
        mutating func encode(_ v: UInt8, forKey key: Key) throws { var s = single(key); try s.encode(v) }
        mutating func encode(_ v: UInt16, forKey key: Key) throws { var s = single(key); try s.encode(v) }
        mutating func encode(_ v: UInt32, forKey key: Key) throws { var s = single(key); try s.encode(v) }
        mutating func encode(_ v: UInt64, forKey key: Key) throws { var s = single(key); try s.encode(v) }
        mutating func encode<T: Encodable>(_ v: T, forKey key: Key) throws { var s = single(key); try s.encode(v) }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
            Writer(box: box.child(forKey: key.stringValue), codingPath: codingPath + [key]).container(keyedBy: NestedKey.self)
        }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
            Writer(box: box.child(forKey: key.stringValue), codingPath: codingPath + [key]).unkeyedContainer()
        }
        mutating func superEncoder() -> Encoder { Writer(box: box.child(forKey: "super"), codingPath: codingPath) }
        mutating func superEncoder(forKey key: Key) -> Encoder { Writer(box: box.child(forKey: key.stringValue), codingPath: codingPath + [key]) }
    }

    struct Unkeyed: UnkeyedEncodingContainer {
        let box: Box
        var codingPath: [CodingKey]
        var count: Int { box.count }
        func single() -> Single { Single(box: box.appendChild(), codingPath: codingPath) }
        mutating func encodeNil() throws { var s = single(); try s.encodeNil() }
        mutating func encode(_ v: Bool) throws { var s = single(); try s.encode(v) }
        mutating func encode(_ v: String) throws { var s = single(); try s.encode(v) }
        mutating func encode(_ v: Double) throws { var s = single(); try s.encode(v) }
        mutating func encode(_ v: Float) throws { var s = single(); try s.encode(v) }
        mutating func encode(_ v: Int) throws { var s = single(); try s.encode(v) }
        mutating func encode(_ v: Int8) throws { var s = single(); try s.encode(v) }
        mutating func encode(_ v: Int16) throws { var s = single(); try s.encode(v) }
        mutating func encode(_ v: Int32) throws { var s = single(); try s.encode(v) }
        mutating func encode(_ v: Int64) throws { var s = single(); try s.encode(v) }
        mutating func encode(_ v: UInt) throws { var s = single(); try s.encode(v) }
        mutating func encode(_ v: UInt8) throws { var s = single(); try s.encode(v) }
        mutating func encode(_ v: UInt16) throws { var s = single(); try s.encode(v) }
        mutating func encode(_ v: UInt32) throws { var s = single(); try s.encode(v) }
        mutating func encode(_ v: UInt64) throws { var s = single(); try s.encode(v) }
        mutating func encode<T: Encodable>(_ v: T) throws { var s = single(); try s.encode(v) }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
            Writer(box: box.appendChild(), codingPath: codingPath).container(keyedBy: NestedKey.self)
        }
        mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
            Writer(box: box.appendChild(), codingPath: codingPath).unkeyedContainer()
        }
        mutating func superEncoder() -> Encoder { Writer(box: box.appendChild(), codingPath: codingPath) }
    }
}
