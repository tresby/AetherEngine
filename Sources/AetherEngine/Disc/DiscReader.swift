import Foundation

/// Detects a DVD-Video ISO and adapts it to the engine's normal demux path.
/// Given a raw ISO `IOReader`, returns a synthetic `IOReader` over the main
/// title's concatenated VOBs plus the demuxer format hint, or nil when the
/// source is not a playable DVD ISO (so the caller falls back to plain demux).
/// No decryption: encrypted retail ISOs parse but their streams will not
/// decode; that surfaces downstream as a normal demux/decode failure.
enum DiscReader {
    /// Cheap content sniff: the ISO9660 "CD001" signature at byte 0x8001.
    static func looksLikeISO9660(_ reader: IOReader) -> Bool {
        guard reader.seek(offset: 0x8001, whence: SEEK_SET) >= 0 else { return false }
        var buf = [UInt8](repeating: 0, count: 5)
        let n = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 5) }
        return n == 5 && buf == Array("CD001".utf8)
    }

    /// Returns `(syntheticReader, formatHint)` for a DVD ISO, else nil.
    static func wrap(_ reader: IOReader) throws -> (IOReader, String)? {
        guard looksLikeISO9660(reader) else { return nil }
        let iso: ISO9660Reader
        do {
            iso = try ISO9660Reader(reader: reader)
        } catch DiscError.notISO9660 {
            return nil
        }
        let files: [DiscFile]
        do {
            files = try iso.list(directory: "VIDEO_TS")
        } catch DiscError.directoryNotFound {
            return nil  // ISO9660 but not a DVD-Video disc (Blu-ray / data disc)
        }
        let titleVOBs = DVDTitleSelector.selectMainTitleVOBs(files)
        guard !titleVOBs.isEmpty else { return nil }
        let extents = titleVOBs.map {
            (offset: Int64($0.startSector * iso.sectorSize), length: Int64($0.length))
        }
        return (ConcatIOReader(base: reader, extents: extents), "mpeg")
    }
}
