import Foundation

/// Selects DVD-Video main title without IFO parsing. VTS_nn_0.VOB = menus;
/// VTS_nn_1..9.VOB = content. Main title = largest total content VOB size.
enum DVDTitleSelector {
    static func selectMainTitleVOBs(_ files: [DiscFile]) -> [DiscFile] {
        struct Part { let title: Int; let part: Int; let file: DiscFile }
        var parts: [Part] = []
        for f in files {
            guard let (title, part) = parseVOBName(f.name), part >= 1 else { continue }
            parts.append(Part(title: title, part: part, file: f))
        }
        guard !parts.isEmpty else { return [] }
        let byTitle = Dictionary(grouping: parts, by: \.title)
        let winner = byTitle.max { a, b in
            a.value.reduce(0) { $0 + $1.file.length } < b.value.reduce(0) { $0 + $1.file.length }
        }
        guard let parts = winner?.value else { return [] }
        return parts.sorted { $0.part < $1.part }.map(\.file)
    }

    /// Parse "VTS_NN_P.VOB" -> (title NN, part P). Case-insensitive.
    static func parseVOBName(_ name: String) -> (title: Int, part: Int)? {
        let upper = name.uppercased()
        guard upper.hasPrefix("VTS_"), upper.hasSuffix(".VOB") else { return nil }
        let stem = upper.dropFirst(4).dropLast(4)        // "NN_P"
        let comps = stem.split(separator: "_")
        guard comps.count == 2, let t = Int(comps[0]), let p = Int(comps[1]) else { return nil }
        return (t, p)
    }
}
