import Foundation

// MARK: - Data ↔ hex

public extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        let chars = Array(hexString)
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes)
    }
}

// MARK: - String JSON escaping

public extension String {
    /// Escapes a string for safe embedding as a JSON string value (without surrounding quotes).
    var jsonStringEscaped: String {
        var out = ""
        out.reserveCapacity(count)
        for char in self {
            switch char {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                let scalar = char.unicodeScalars.first!.value
                if scalar < 0x20 {
                    out += String(format: "\\u%04x", scalar)
                } else {
                    out.append(char)
                }
            }
        }
        return out
    }
}
