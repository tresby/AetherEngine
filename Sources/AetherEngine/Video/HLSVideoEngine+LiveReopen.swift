import Foundation

extension HLSVideoEngine {

    func handlePumpFinished(_ prod: HLSSegmentProducer,
                                    reason: HLSSegmentProducer.PumpExitReason) {
        guard isLiveSession else { return }
        switch reason {
        case .stopRequested, .muxerFailed:
            return
        case .sourceReplay:
            // Server restarted stream from beginning (Jellyfin transcode respawn); URL reopen would replay stale content. Delegate to host for fresh negotiation.
            EngineLog.emit(
                "[HLSVideoEngine] live source replayed from start after reconnect; "
                + "requesting host retune (fresh playback session)",
                category: .session
            )
            onLiveSourceReset?()
            return
        case .segmentStall:
            // SSAI ad pod the cutter can't cut through; URL reopen would re-enter it. Delegate to host for server-muxed fallback.
            EngineLog.emit(
                "[HLSVideoEngine] live segment cutter stalled (likely SSAI ad pod); "
                + "requesting host retune to the server route",
                category: .session
            )
            onLiveSourceReset?()
            return
        case .eof, .readError, .keyframeStarvation:
            // Custom-reader sources (e.g. live HLS ingest) own their own reconnection; URL reopen burns the backoff budget on guaranteed failures.
            if !sourceReopenableByURL {
                EngineLog.emit(
                    "[HLSVideoEngine] live custom-source pump exited (reason=\(reason)); "
                    + "URL reopen not possible, requesting host retune",
                    category: .session
                )
                onLiveSourceReset?()
                return
            }
        }
        restartLock.lock()
        let segmentsNow = provider?.liveContinuationPoint().nextIndex ?? 0
        if segmentsNow == lastReopenSegmentCount {
            barrenReopenCycles += 1
        } else {
            barrenReopenCycles = 0
        }
        lastReopenSegmentCount = segmentsNow
        let barrenNow = barrenReopenCycles
        restartLock.unlock()
        if barrenNow >= Self.maxBarrenReopenCycles {
            EngineLog.emit(
                "[HLSVideoEngine] live source produced no segments across "
                + "\(barrenNow) reopen cycles; giving up (source considered dead)",
                category: .session
            )
            return
        }
        EngineLog.emit(
            "[HLSVideoEngine] live pump exited (reason=\(reason)); starting reopen",
            category: .session
        )
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.performLiveReopen(failedProducer: prod)
        }
    }

    private func performLiveReopen(failedProducer: HLSSegmentProducer) async {
        for attempt in 1...Self.liveReopenMaxAttempts {
            guard currentProducerIs(failedProducer) else { return }

            let delay = min(0.5 * pow(2.0, Double(attempt - 1)), 8.0)  // capped exponential backoff: 0.5..8s (~23s total)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            let dem = Demuxer()
            registerReopenDemuxer(dem)  // register before blocking open so stop() can abort via markClosed
            defer { unregisterReopenDemuxer(dem) }
            do {
                try dem.open(url: sourceURL, extraHeaders: sourceHTTPHeaders, isLive: true)
            } catch {
                EngineLog.emit(
                    "[HLSVideoEngine] live reopen attempt \(attempt)/\(Self.liveReopenMaxAttempts) failed: \(error)",
                    category: .session
                )
                dem.close()
                continue
            }
            // Reopened producer reuses savedVideoConfig/savedAudioConfig (stream indices + time bases from original probe); layout mismatch means server changed transcode shape.
            guard dem.videoStreamIndex == videoStreamIndex else {
                EngineLog.emit(
                    "[HLSVideoEngine] live reopen attempt \(attempt): video stream index "
                    + "changed (\(dem.videoStreamIndex) != \(videoStreamIndex)), retrying",
                    category: .session
                )
                dem.close()
                continue
            }

            switch finishLiveReopen(failedProducer: failedProducer, dem: dem, attempt: attempt) {
            case .done, .aborted:
                return
            case .retry:
                continue
            }
        }
        EngineLog.emit(
            "[HLSVideoEngine] live reopen FAILED after \(Self.liveReopenMaxAttempts) attempts; "
            + "source considered permanently lost",
            category: .session
        )
    }

    /// NSLock unavailable from async contexts; this synchronous helper wraps the check.
    private func currentProducerIs(_ p: HLSSegmentProducer) -> Bool {
        restartLock.lock()
        defer { restartLock.unlock() }
        return producer === p
    }

    private func registerReopenDemuxer(_ dem: Demuxer) {
        restartLock.lock()
        reopenDemuxer = dem
        restartLock.unlock()
    }

    private func unregisterReopenDemuxer(_ dem: Demuxer) {
        restartLock.lock()
        if reopenDemuxer === dem { reopenDemuxer = nil }
        restartLock.unlock()
    }

    private enum LiveReopenOutcome { case done, aborted, retry }

    private func finishLiveReopen(failedProducer: HLSSegmentProducer,
                                  dem: Demuxer,
                                  attempt: Int) -> LiveReopenOutcome {
        restartLock.lock()
        guard producer === failedProducer, let prov = provider else {
            restartLock.unlock()
            dem.close()
            return .aborted
        }
        let oldDem = demuxer
        demuxer = dem
        let (nextIndex, outputEnd) = prov.liveContinuationPoint()
        do {
            let newProd = try makeProducer(
                baseIndex: nextIndex,
                liveReopenOutputEndSeconds: outputEnd
            )
            // Fresh connection joins the broadcast at "now"; source clock jumps, so the seam carries #EXT-X-DISCONTINUITY. Shift handoff deferred to seam to avoid jumping the host clock while pre-loss content is on screen.
            newProd.firstSegmentDiscontinuous = true
            newProd.onVideoShiftKnown = { [weak self] shiftPts in
                self?.handleLiveTimelineRebase(shiftPts, seamOutputSeconds: outputEnd)
            }
            producer = newProd
            restartLock.unlock()
            oldDem?.close()
            newProd.start()
            EngineLog.emit(
                "[HLSVideoEngine] live reopen succeeded on attempt \(attempt): "
                + "continuing at seg\(nextIndex) (outputEnd=\(String(format: "%.1f", outputEnd))s)",
                category: .session
            )
            return .done
        } catch {
            demuxer = oldDem
            restartLock.unlock()
            dem.close()
            EngineLog.emit(
                "[HLSVideoEngine] live reopen attempt \(attempt): producer build failed (\(error))",
                category: .session
            )
            return .retry
        }
    }
}
