import AVFoundation
import Foundation

/// `AVAssetResourceLoaderDelegate` that serves HLS playlists, init.mp4,
/// and media segments directly from an `HLSSegmentProvider` instead of
/// going through `HLSLocalServer` + HTTP-loopback. Designed to fix the
/// long-form memory leak where CFNetwork's loopback I/O buffer pool
/// (`VM: libnetwork`) grew unboundedly with playback time:
///
///   - keep-alive: ~545 KB pool chunks accumulated per segment served
///     (Instruments showed 66 MiB persistent at ~5 min, 100% retention)
///   - Connection: close shifted the same leak into direct heap as
///     ~10 MiB `Malloc` blocks (570 MiB at the same duration) — strictly
///     worse since CFNetwork couldn't reuse pool chunks
///
/// Eliminating CFNetwork from the segment-serve path entirely (custom
/// `aether-engine://` scheme → delegate callback) sidesteps the pool
/// growth altogether. AVPlayer's own HLS parser is already known
/// leak-free (verified against a Mac LAN HTTP server serving the same
/// content with stable RSS over 90+ seconds).
///
/// Trade-off: custom-scheme URLs are NOT AirPlay-compatible. Caller
/// must set `allowsExternalPlayback = false` on the resulting AVPlayer
/// to avoid silent AirPlay failures. tvOS apps rarely AirPlay-OUT (the
/// device is normally the receiver), so the loss is acceptable.
///
/// Thread safety: AVFoundation calls the delegate methods on the queue
/// passed to `setDelegate(_:queue:)`. We use one serial queue per
/// instance. `HLSSegmentProvider` implementations are already thread-
/// safe (NSCondition-locked SegmentCache, NSLock-guarded HLSVideoEngine
/// state).
final class EngineResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {

    /// Custom URL scheme AVPlayer will route through this delegate
    /// rather than CFNetwork. Picked to be unmistakable in logs and
    /// trivially-routable in `shouldWaitForLoadingOfRequestedResource`.
    static let scheme = "aether-engine"

    /// Host part of the placeholder URLs we hand AVPlayer. Empty path
    /// or `/` would confuse relative-URL resolution inside the playlist
    /// (HLS playlists reference segments by relative URL — `seg42.mp4`
    /// — and AVPlayer resolves those against the playlist's own URL).
    static let host = "engine"

    /// Build the playback URL for a session. AVPlayer creates an
    /// `AVURLAsset` from this and the delegate handles every byte
    /// request that flows from `asset.load(...)`, `AVPlayerItem`
    /// initialisation, and ongoing playback.
    static func playbackURL(useMasterPlaylist: Bool) -> URL {
        let path = useMasterPlaylist ? "master.m3u8" : "media.m3u8"
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/\(path)"
        guard let url = components.url else {
            // URLComponents with our constants always produces a URL,
            // but the API is failable. Fallback uses string literal.
            return URL(string: "\(scheme)://\(host)/\(path)")!
        }
        return url
    }

    /// Serial queue AVFoundation invokes our delegate methods on. One
    /// per delegate instance so callbacks for one session can't block
    /// another session.
    let queue: DispatchQueue

    private weak var provider: HLSSegmentProvider?

    /// `true` once the engine routed the asset through the master
    /// playlist (HDR / DV signalling). Used by `handlePlaylist` to
    /// know whether to serve master or media when the URL path is
    /// the root.
    private let servingMasterPlaylist: Bool

    /// Lifetime cumulative bytes the delegate has handed to AVPlayer.
    /// Surfaced into the engine memprobe so we can verify the new
    /// path is actually taken vs. silently falling back to the HTTP
    /// loopback (which would show zero delegate bytes).
    private let byteCounterLock = NSLock()
    private var _lifetimeBytesServed: Int = 0
    var lifetimeBytesServed: Int {
        byteCounterLock.lock()
        defer { byteCounterLock.unlock() }
        return _lifetimeBytesServed
    }
    private func bumpBytesServed(_ n: Int) {
        guard n > 0 else { return }
        byteCounterLock.lock()
        _lifetimeBytesServed &+= n
        byteCounterLock.unlock()
    }

    init(provider: HLSSegmentProvider, servingMasterPlaylist: Bool) {
        self.provider = provider
        self.servingMasterPlaylist = servingMasterPlaylist
        self.queue = DispatchQueue(
            label: "AetherEngine.ResourceLoader",
            qos: .userInitiated
        )
        super.init()
    }

    // MARK: - AVAssetResourceLoaderDelegate

    /// AVFoundation calls this for every resource it wants us to load.
    /// Return `true` to indicate we'll handle it (we MUST call
    /// `finishLoading()` or `finishLoading(with:)` later, either
    /// synchronously here or asynchronously). Return `false` to let
    /// AVFoundation try its default behaviour — which for a custom
    /// scheme is to fail with an unsupported-scheme error.
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url,
              url.scheme == Self.scheme else {
            return false
        }

        // Path is `/master.m3u8`, `/media.m3u8`, `/init.mp4`,
        // `/seg42.mp4`. Strip the leading slash.
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path

        switch path {
        case "master.m3u8":
            return handlePlaylist(loadingRequest: loadingRequest, isMaster: true)
        case "media.m3u8":
            return handlePlaylist(loadingRequest: loadingRequest, isMaster: false)
        case "init.mp4":
            return handleInitSegment(loadingRequest: loadingRequest)
        default:
            if path.hasPrefix("seg"), path.hasSuffix(".mp4") {
                let indexStr = path.dropFirst("seg".count).dropLast(".mp4".count)
                if let index = Int(indexStr), index >= 0 {
                    return handleMediaSegment(loadingRequest: loadingRequest, index: index)
                }
            }
            EngineLog.emit("[ResourceLoader] unknown path: \(path)",
                           category: .hlsServer)
            loadingRequest.finishLoading(with: URLError(.fileDoesNotExist))
            return true
        }
    }

    /// Cancel notification for an in-flight loading request. We don't
    /// hold any per-request resources beyond the synchronous call, so
    /// there's nothing to undo here. Logged for diagnostics.
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let url = loadingRequest.request.url?.absoluteString ?? "?"
        EngineLog.emit("[ResourceLoader] cancelled: \(url)", category: .hlsServer)
    }

    // MARK: - Path handlers

    private func handlePlaylist(
        loadingRequest: AVAssetResourceLoadingRequest,
        isMaster: Bool
    ) -> Bool {
        guard let provider = provider else {
            loadingRequest.finishLoading(with: URLError(.cancelled))
            return true
        }
        let text: String
        if isMaster {
            text = HLSLocalServer.buildMasterPlaylistText(provider: provider)
        } else {
            text = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        }
        let data = Data(text.utf8)
        loadingRequest.contentInformationRequest?.contentType = "application/vnd.apple.mpegurl"
        loadingRequest.contentInformationRequest?.contentLength = Int64(data.count)
        loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
        respondAndFinish(loadingRequest, with: data)
        return true
    }

    private func handleInitSegment(loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let provider = provider,
              let data = provider.initSegment(), !data.isEmpty else {
            EngineLog.emit("[ResourceLoader] init.mp4 not available", category: .hlsServer)
            loadingRequest.finishLoading(with: URLError(.resourceUnavailable))
            return true
        }
        loadingRequest.contentInformationRequest?.contentType = "video/mp4"
        loadingRequest.contentInformationRequest?.contentLength = Int64(data.count)
        loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = true
        respondAndFinish(loadingRequest, with: data)
        return true
    }

    /// Media segment via the cache's file URL when available. Reads
    /// the file in 256 KB chunks and feeds each chunk to AVPlayer via
    /// `dataRequest.respond(with:)`. Constant per-request memory; the
    /// total segment never sits in our heap as a single Data wrapper.
    private func handleMediaSegment(
        loadingRequest: AVAssetResourceLoadingRequest,
        index: Int
    ) -> Bool {
        guard let provider = provider else {
            loadingRequest.finishLoading(with: URLError(.cancelled))
            return true
        }

        // Prefer the file-URL path so we can stream chunks; fall back
        // to the in-memory Data path for the BufferedSegmentProvider
        // (audio engine) which isn't file-backed.
        if let fileURL = provider.mediaSegmentURL(at: index) {
            return serveSegmentFile(loadingRequest: loadingRequest,
                                     fileURL: fileURL,
                                     index: index)
        }
        if let data = provider.mediaSegment(at: index), !data.isEmpty {
            loadingRequest.contentInformationRequest?.contentType = "video/mp4"
            loadingRequest.contentInformationRequest?.contentLength = Int64(data.count)
            loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = true
            respondAndFinish(loadingRequest, with: data)
            return true
        }
        let providerCount = provider.segmentCount
        EngineLog.emit("[ResourceLoader] seg[\(index)] unavailable (segmentCount=\(providerCount))",
                       category: .hlsServer)
        loadingRequest.finishLoading(with: URLError(.resourceUnavailable))
        return true
    }

    private func serveSegmentFile(
        loadingRequest: AVAssetResourceLoadingRequest,
        fileURL: URL,
        index: Int
    ) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs?[.size] as? Int) ?? 0
        if fileSize == 0 {
            EngineLog.emit("[ResourceLoader] seg[\(index)] empty file at \(fileURL.lastPathComponent)",
                           category: .hlsServer)
            loadingRequest.finishLoading(with: URLError(.resourceUnavailable))
            return true
        }

        loadingRequest.contentInformationRequest?.contentType = "video/mp4"
        loadingRequest.contentInformationRequest?.contentLength = Int64(fileSize)
        loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = true

        // Range request: AVPlayer can request part of the file. Default
        // values cover "whole resource" when AVPlayer hasn't asked for
        // a specific range.
        let requestedOffset: Int
        let requestedLength: Int
        if let dataRequest = loadingRequest.dataRequest {
            requestedOffset = Int(dataRequest.requestedOffset)
            if dataRequest.requestsAllDataToEndOfResource {
                requestedLength = fileSize - requestedOffset
            } else {
                requestedLength = min(dataRequest.requestedLength, fileSize - requestedOffset)
            }
        } else {
            requestedOffset = 0
            requestedLength = fileSize
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            EngineLog.emit("[ResourceLoader] seg[\(index)] open failed: \(error)",
                           category: .hlsServer)
            loadingRequest.finishLoading(with: error)
            return true
        }
        defer { try? handle.close() }

        if requestedOffset > 0 {
            do {
                try handle.seek(toOffset: UInt64(requestedOffset))
            } catch {
                EngineLog.emit("[ResourceLoader] seg[\(index)] seek failed: \(error)",
                               category: .hlsServer)
                loadingRequest.finishLoading(with: error)
                return true
            }
        }

        let chunkSize = 256 * 1024
        var remaining = requestedLength
        var totalServed = 0
        while remaining > 0 {
            let toRead = min(chunkSize, remaining)
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: toRead) ?? Data()
            } catch {
                EngineLog.emit("[ResourceLoader] seg[\(index)] read failed: \(error)",
                               category: .hlsServer)
                loadingRequest.finishLoading(with: error)
                return true
            }
            if chunk.isEmpty {
                // EOF before remaining drained — treat as completion of
                // what we could deliver. AVPlayer is fine with a short
                // response when the data ends before requestedLength.
                break
            }
            loadingRequest.dataRequest?.respond(with: chunk)
            totalServed += chunk.count
            remaining -= chunk.count
        }
        loadingRequest.finishLoading()
        bumpBytesServed(totalServed)
        EngineLog.emit("[ResourceLoader] seg[\(index)] served \(totalServed) B (offset=\(requestedOffset) requested=\(requestedLength))",
                       category: .hlsServer)
        return true
    }

    private func respondAndFinish(
        _ loadingRequest: AVAssetResourceLoadingRequest,
        with data: Data
    ) {
        // Honour any byte-range subselection on small responses too;
        // playlist requests can in principle ask for a range though
        // AVPlayer typically asks for the whole playlist body.
        if let dataRequest = loadingRequest.dataRequest {
            let offset = Int(dataRequest.requestedOffset)
            let count: Int
            if dataRequest.requestsAllDataToEndOfResource {
                count = data.count - offset
            } else {
                count = min(dataRequest.requestedLength, data.count - offset)
            }
            if offset >= 0, offset + count <= data.count {
                let slice = data.subdata(in: offset..<(offset + count))
                dataRequest.respond(with: slice)
                bumpBytesServed(slice.count)
            } else {
                dataRequest.respond(with: data)
                bumpBytesServed(data.count)
            }
        }
        loadingRequest.finishLoading()
    }
}
