import Foundation

/// Stateless tx3g (mov_text) sample builder (#55): uint16 BE byte-length prefix + UTF-8 text, no style boxes (plain text for broad AVPlayer compat).
enum MovTextSampleBuilder {

    /// `[uint16 BE byte-length][UTF-8 text]`, ASS markup stripped.
    static func sample(text: String) -> Data {
        let clean = sanitize(text)
        let utf8 = Array(clean.utf8)
        let len = min(utf8.count, 0xFFFF)
        var data = Data([UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
        data.append(contentsOf: utf8.prefix(len))
        return data
    }

    /// Zero-length mov_text sample fills gaps between cues so the track stays contiguous.
    static func emptySample() -> Data {
        Data([0x00, 0x00])
    }

    /// Strip ASS/SSA override blocks (`{\...}`) and normalize inline escapes mov_text cannot carry; plain text only.
    static func sanitize(_ assText: String) -> String {
        var s = assText
        while let open = s.firstIndex(of: "{"), let close = s[open...].firstIndex(of: "}") {
            s.removeSubrange(open...close)
        }
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\h", with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
