import Foundation

/// A DVD-Video title from the VMGI Title Search Pointer Table (TT_SRPT). Maps the disc's user-visible
/// titles onto the title sets (VTS) that back them, with each title's chapter count (#67).
struct DVDIFOTitle: Equatable {
    /// 1-based title-set number (VTS_NN_*). The whole-VTS title resolution concatenates this VTS's VOBs.
    let vtsn: Int
    /// Title number within its VTS (vts_ttn). Multiple titles can share a VTS (episodic TV).
    let vtsTitleNumber: Int
    /// Number of parts-of-title (PTTs = chapters) in this title. Surfaced for chapter enumeration (Phase 4).
    let chapterCount: Int
    /// Number of angles (1 for non-multiangle titles).
    let angleCount: Int
}

/// Parses the DVD-Video Video Manager (VIDEO_TS.IFO / VMGI) just far enough to enumerate titles. The
/// VMGI_MAT holds the TT_SRPT start sector at byte offset 0xC4; TT_SRPT lists every title with the VTS
/// that backs it. Byte layout per libdvdread's ifo_types (tt_srpt_t / title_info_t).
enum DVDIFOParser {
    private static let vmgMagic = Array("DVDVIDEO-VMG".utf8)
    private static let sectorSize = 2048
    /// VMGI_MAT offset of the 4-byte TT_SRPT start-sector pointer.
    private static let ttSrptPointerOffset = 0xC4

    /// Returns the disc's titles from TT_SRPT, or nil if the bytes are not a recognizable VMGI / the table
    /// is malformed or out of range (the caller then falls back to the VOB-size heuristic).
    static func parseTitles(_ data: [UInt8]) -> [DVDIFOTitle]? {
        guard data.count >= ttSrptPointerOffset + 4,
              Array(data[0..<12]) == vmgMagic else { return nil }
        let ttSrptSector = be32(data, ttSrptPointerOffset)
        // Sector 0 would overlap the VMGI header; treat as absent.
        guard ttSrptSector > 0 else { return nil }
        let base = ttSrptSector * sectorSize
        // TT_SRPT header: nr_of_titles(2) + reserved(2) + last_byte(4) = 8 bytes, then 12-byte entries.
        guard base + 8 <= data.count else { return nil }
        let nrTitles = be16(data, base)
        guard nrTitles > 0 else { return nil }
        var titles: [DVDIFOTitle] = []
        titles.reserveCapacity(nrTitles)
        for i in 0..<nrTitles {
            let entry = base + 8 + i * 12
            guard entry + 12 <= data.count else { break }
            let angles = Int(data[entry + 1])
            let ptts = be16(data, entry + 2)
            let vtsn = Int(data[entry + 6])
            let ttn = Int(data[entry + 7])
            // A title must name a real (1-based) title set; skip a corrupt zero entry rather than abort.
            guard vtsn > 0 else { continue }
            titles.append(DVDIFOTitle(vtsn: vtsn, vtsTitleNumber: ttn, chapterCount: ptts, angleCount: angles))
        }
        return titles.isEmpty ? nil : titles
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> Int { (Int(b[i]) << 8) | Int(b[i+1]) }
    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 24) | (Int(b[i+1]) << 16) | (Int(b[i+2]) << 8) | Int(b[i+3])
    }
}
