import Foundation

/// Just enough of the protocol-buffers wire format to read the two blobs WhatsApp stores a
/// message's reactions and quote in. No schema, no generated code: a field is a number and
/// either an integer or some bytes, and the callers name the numbers they know.
///
/// A malformed blob yields no fields at all rather than the fields before the damage. A
/// half-read reaction list would be reported as the whole list, and a wrong "nobody reacted"
/// is worse than saying nothing.
enum ProtobufWire {
    struct Field: Equatable {
        let number: Int
        /// Set for a varint field.
        let integer: UInt64?
        /// Set for a length-delimited field (strings, bytes, nested messages).
        let bytes: Data?

        var string: String? { bytes.flatMap { String(data: $0, encoding: .utf8) } }
    }

    /// Nested messages are read one level at a time by the callers, so no depth limit is
    /// needed here; the size limit keeps a hostile blob from costing more than its length.
    static func fields(_ data: Data) -> [Field] {
        var result: [Field] = []
        var index = data.startIndex
        let end = data.endIndex

        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < end, shift < 64 {
                let byte = data[index]
                index = data.index(after: index)
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }

        while index < end {
            guard let key = varint(), key >> 3 > 0, key >> 3 <= UInt64(Int32.max) else { return [] }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint() else { return [] }
                result.append(Field(number: number, integer: value, bytes: nil))
            case 1, 5:
                let width = (key & 7) == 1 ? 8 : 4
                guard end - index >= width else { return [] }
                index = data.index(index, offsetBy: width)
            case 2:
                guard let length = varint(), length <= UInt64(end - index) else { return [] }
                let stop = data.index(index, offsetBy: Int(length))
                result.append(Field(number: number, integer: nil, bytes: data[index..<stop]))
                index = stop
            default:
                return []
            }
        }
        return result
    }
}
