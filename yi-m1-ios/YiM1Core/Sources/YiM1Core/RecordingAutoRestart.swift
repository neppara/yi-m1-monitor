// Pure timer math for the recording auto-restart feature (I4, 2026-07-12) - kept separate from
// CameraSession so it's independently testable without a running session.
//
// True nonstop recording is impossible on the YI M1 (firmware repack is unsafe, HDMI is
// playback-only, FAT32 is required - see DEVELOPMENT_PLAN.md's recording-limits research), so
// this is the achievable ceiling: proactively stop/start just under the camera's own limits so
// the app - not the camera - controls when the gap happens. Two known caps: ~30 minutes general,
// and 4K clips fixed at ~8.5 minutes (4GB FAT32 file-size ceiling). It's still an OPEN QUESTION
// (the user's own on-device stopwatch-across-the-boundary test will answer it) whether 4K
// actually keeps recording into a seamlessly-split new file at that boundary, in which case only
// the 30-minute cap would matter for it too - if so, `fourKRestartInterval` just needs bumping to
// match `fhdRestartInterval`.
import Foundation

public enum RecordingAutoRestart {
    // Margins tuned by the user (2026-07-12) after the first confirmed-working field run of
    // auto-restart - tighter than the initial conservative values, trading safety margin for
    // less lost tail per clip. The fps-signature detector (CameraSession's camera-self-stop
    // detection) is the safety net if the camera's own stop ever beats one of these timers.

    /// 5s under the ~30-minute general recording cap (its exact value is approximate - if the
    /// camera actually stops a few seconds early, the fps detector catches it).
    public static let fhdRestartInterval: TimeInterval = 29 * 60 + 55
    /// 6s under the camera's field-measured 4K stop at 7:29/~4096MB (4GB FAT32 file ceiling;
    /// confirmed by the 2026-07-12 continuous-recording run: 7:00 restarts produced ~3800MB
    /// files, extrapolating exactly to 4GB at the observed 7:29 self-stop).
    public static let fourKRestartInterval: TimeInterval = 7 * 60 + 23
    /// 10s under the general 30-minute cap - the only limit documented for 2K (2048x1536, 4:3
    /// full-sensor downscale; research never measured a 2K bitrate). CAVEAT: if the 2K bitrate
    /// exceeds ~18 Mbit/s, the 4GB file ceiling would arrive BEFORE 30 minutes and this timer
    /// would miss it - the fps detector covers that case, and one deliberate 2K recording left
    /// to run until the camera stops itself would pin the real number.
    public static let twoKRestartInterval: TimeInterval = 29 * 60 + 50
    /// Used whenever the current format isn't recognized - restarting a bit early on an
    /// unrecognized format is far cheaper than risking a silent hard stop at the camera's own
    /// undocumented limit for it.
    public static let defaultRestartInterval: TimeInterval = fhdRestartInterval

    /// Picks the restart interval for a `VideoFormat` metadata string, using the same
    /// prefix-match convention as `MeasuredCrops.video` (e.g. "4K_24" matches "4K").
    public static func restartInterval(forVideoFormat videoFormat: String?) -> TimeInterval {
        guard let videoFormat else { return defaultRestartInterval }
        if videoFormat.hasPrefix("4K") { return fourKRestartInterval }
        if videoFormat.hasPrefix("2K") { return twoKRestartInterval }
        return defaultRestartInterval
    }

    /// True once `elapsed` (time since the current clip's VideoRecordingStart succeeded) has
    /// reached the restart interval for the given format.
    public static func isRestartDue(elapsed: TimeInterval, videoFormat: String?) -> Bool {
        elapsed >= restartInterval(forVideoFormat: videoFormat)
    }
}
