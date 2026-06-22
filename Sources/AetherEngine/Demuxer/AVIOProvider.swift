import Libavformat

/// Abstraction over a custom-AVIO byte source attached to `AVFormatContext.pb`.
/// `AVIOReader` (HTTP) and `CustomIOReaderBridge` (custom `IOReader`) both conform.
protocol AVIOProvider: AnyObject {
    /// Allocated `AVIOContext`, valid between `open()` and `close()`.
    var context: UnsafeMutablePointer<AVIOContext>? { get }

    /// Bytes fetched since open (memory-probe use). Custom readers that do not
    /// track network I/O report 0.
    var cumulativeBytesFetched: Int64 { get }

    /// Forward-only sources report false; keeps them off the native seek path.
    var isSeekable: Bool { get }

    func open() throws

    /// Fast, allocation-free: unblock a suspended read so the demuxer's access
    /// lock can be acquired during teardown. Call before `close()`.
    func markClosed()

    /// Free the `AVIOContext` and release the underlying source. Idempotent.
    func close()
}
