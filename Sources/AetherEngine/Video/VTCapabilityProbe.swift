import Foundation
import VideoToolbox
import CoreMedia

/// Cached VTIsHardwareDecodeSupported probe after VTRegisterSupplementalVideoDecoderIfAvailable. Cached on first access; registration is idempotent.
enum VTCapabilityProbe {

    /// True only when AVPlayer's HLS-fMP4 pipeline can HW-decode AV1. Apple's dav1d (macOS 14+/iOS 17+) is reachable via direct file playback but NOT via AVPlayer HLS in practice (verified 2026-05-14 on M1 macOS 26.4): VTIsHardwareDecodeSupported returns false, AVURLAsset.isPlayable returns false. False routes to SoftwarePlaybackHost/dav1d.
    static let av1Available: Bool = {
        if #available(tvOS 26.2, iOS 26.2, macOS 16.0, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
        }
        if #available(tvOS 17.0, iOS 17.0, macOS 14.0, *) {
            let supported = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
            EngineLog.emit("[VTProbe] codec=av01 hwSupported=\(supported)", category: .engine)
            return supported
        }
        EngineLog.emit("[VTProbe] codec=av01 hwSupported=false (pre-iOS17/tvOS17)", category: .engine)
        return false
    }()

}
