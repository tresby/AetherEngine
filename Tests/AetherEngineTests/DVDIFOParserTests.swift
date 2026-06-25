import XCTest
@testable import AetherEngine

/// Parsing the DVD-Video VMGI (VIDEO_TS.IFO) TT_SRPT into the title->VTS map (#67 Phase 3).
final class DVDIFOParserTests: XCTestCase {
    private func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
    private func be32(_ v: Int) -> [UInt8] {
        [UInt8((v>>24)&0xff), UInt8((v>>16)&0xff), UInt8((v>>8)&0xff), UInt8(v&0xff)]
    }
    /// One 12-byte TT_SRPT title entry: playback(1) angles(1) nr_ptts(2) parental(2) vtsn(1) vts_ttn(1) sector(4).
    private func ttEntry(angles: Int, ptts: Int, vtsn: Int, ttn: Int) -> [UInt8] {
        var e = [UInt8]()
        e.append(0)
        e.append(UInt8(angles))
        e += be16(ptts)
        e += be16(0)
        e.append(UInt8(vtsn))
        e.append(UInt8(ttn))
        e += be32(0)
        return e
    }
    /// VMGI with "DVDVIDEO-VMG" magic, tt_srpt sector pointer at 0xC4, and the TT_SRPT table at that sector.
    private func makeVMGI(entries: [[UInt8]], ttSrptSector: Int = 1) -> [UInt8] {
        let flat = entries.flatMap { $0 }
        var ttSrpt = [UInt8]()
        ttSrpt += be16(entries.count)             // nr_of_titles
        ttSrpt += be16(0)                         // reserved
        ttSrpt += be32(8 + flat.count - 1)        // last_byte (end address)
        ttSrpt += flat
        var ifo = [UInt8]()
        ifo += Array("DVDVIDEO-VMG".utf8)         // 12 bytes @ 0
        ifo += [UInt8](repeating: 0, count: 0xC4 - ifo.count)
        ifo += be32(ttSrptSector)                 // @ 0xC4 tt_srpt start sector
        let ttSrptOffset = ttSrptSector * 2048
        ifo += [UInt8](repeating: 0, count: ttSrptOffset - ifo.count)
        ifo += ttSrpt
        return ifo
    }

    func test_parsesTitlesWithVTSAndChapterCount() {
        let ifo = makeVMGI(entries: [
            ttEntry(angles: 1, ptts: 5, vtsn: 1, ttn: 1),   // main feature, VTS 1, 5 chapters
            ttEntry(angles: 1, ptts: 3, vtsn: 2, ttn: 1),   // extra, VTS 2, 3 chapters
        ])
        let titles = try! XCTUnwrap(DVDIFOParser.parseTitles(ifo))
        XCTAssertEqual(titles.map(\.vtsn), [1, 2])
        XCTAssertEqual(titles.map(\.chapterCount), [5, 3])
    }

    func test_episodicTitlesShareAVTS() {
        // Two PGC titles in the same VTS (episodic TV): the raw list keeps both; whole-VTS dedup is the caller's job.
        let ifo = makeVMGI(entries: [
            ttEntry(angles: 1, ptts: 6, vtsn: 1, ttn: 1),
            ttEntry(angles: 1, ptts: 6, vtsn: 1, ttn: 2),
        ])
        let titles = try! XCTUnwrap(DVDIFOParser.parseTitles(ifo))
        XCTAssertEqual(titles.map(\.vtsn), [1, 1])
    }

    func test_nilOnBadMagic() {
        XCTAssertNil(DVDIFOParser.parseTitles(Array("NOTADVDVIDEO".utf8) + [UInt8](repeating: 0, count: 4096)))
    }

    func test_nilWhenTTSrptSectorOutOfRange() {
        let ifo = makeVMGI(entries: [ttEntry(angles: 1, ptts: 2, vtsn: 1, ttn: 1)], ttSrptSector: 999)
        // The pointer references a sector far past the truncated buffer.
        XCTAssertNil(DVDIFOParser.parseTitles(Array(ifo.prefix(4096))))
    }
}
