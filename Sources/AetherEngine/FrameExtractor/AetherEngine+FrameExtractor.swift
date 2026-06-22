import Foundation

extension AetherEngine {
    /// Vends a `FrameExtractor` for the currently loaded source, or nil if nothing
    /// loaded. URL sources use URL + HTTP headers; custom IOReader sources use an
    /// independent reader clone (nil when the reader is forward-only / one-shot).
    /// Caller owns the extractor's lifecycle (engine does not retain it); call
    /// shutdown() for prompt teardown, else the idle-close timer cleans up.
    /// For arbitrary items (Recents), construct FrameExtractor(url:httpHeaders:) directly.
    public func makeFrameExtractor() -> FrameExtractor? {
        if isCustomSource {
            // Scrub preview runs a second demuxer concurrently with playback, so it
            // needs an independent reader; nil (scrub skipped) if the source can't clone.
            guard let clone = customReader?.makeIndependentReader() else { return nil }
            return FrameExtractor(reader: clone, formatHint: customFormatHint)
        }
        guard let url = loadedURL else { return nil }
        return FrameExtractor(url: url, httpHeaders: loadedOptions.httpHeaders)
    }
}
