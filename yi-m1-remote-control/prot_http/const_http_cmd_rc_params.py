from enum import Enum

class RcLensStatus(str, Enum):
    Disconnected = "0"
    Automatic = "1"
    Manual = "2"
    Unknown = "3"

class RcMeteringMode(str, Enum):
    Multi = "Multi"
    Spot = "Spot"
    CenterWeighted = "CenterWeighted"

class RcExposureMode(str, Enum):
    Auto = "Auto"
    Program = "P"
    AperturePriority = "A"
    ShutterPriority = "S"
    Manual = "M"
    # "Scene", not "C". The inherited map had C/"MasterGuide", but the camera's own value table
    # (.data 0xc09c2c68) lists exactly: Auto, P, A, S, M, Scene - there is no C. "Scene" was
    # additionally accepted by a real camera (2026-07-24), "C" would just be rejected.
    Scene = "Scene"

class RcFocusMode(str, Enum):
    ContrastAutofocus = "C-AF"
    SingleAreaAutofocus = "S-AF"
    ManualFocus = "MF"

class RcTriggerFocusMode(str, Enum):
    Auto = "Auto"
    Manual = "Manual"

class RcImageQuality(str, Enum):
    MP50_Interpolated = "50"
    MP20 = "20"
    MP16 = "16"
    MP8 = "8"
    MP3 = "3"
    VGA = "VGA"

class RcImageAspect(str, Enum):
    A43 = "4:3"
    A32 = "3:2"
    Widescreen = "16:9"
    Square = "1:1"

class RcFileFormat(str, Enum):
    Raw = "RAW"
    JpegSmall = "JPG-S"
    JpegMedium = "JPG-M"
    JpegLarge = "JPG-L"
    RawAndJpegSmall = "RAWJ-S"
    RawAndJpegMedium = "RAWJ-M"
    RawAndJpegLarge = "RAWJ-L"

class RcDriveMode(str, Enum):
    Single = "Single"
    Continuous = "Continuous"
    Delay2 = "2SDelay"
    Delay10 = "10SDelay"

class RcFStop(str, Enum):
    # Confirmed live 2026-07-24 by metadata echo. WEAKER EVIDENCE than the other additions:
    # RCFNSet was the one command that accepted a deliberately bogus value ("99.9") in the
    # negative control, so "accepted" alone proves nothing for it. The likely reason is that
    # the test camera has no electronically recognised lens, so there is no aperture to
    # actually drive and the value is just stored. Metadata did echo these four back exactly.
    # Also learned: 10.0/11.0 get normalised by the camera to "10"/"11", so the existing
    # no-decimal spelling was right.
    F2p9 = "2.9"
    F3p6 = "3.6"
    F6p4 = "6.4"
    F8p4 = "8.4"
    F1p0 = "1.0"
    F1p2 = "1.2"
    F1p4 = "1.4"
    F1p7 = "1.7"
    F1p8 = "1.8"
    F2p0 = "2.0"
    F2p2 = "2.2"
    F2p5 = "2.5"
    F2p8 = "2.8"
    F3p2 = "3.2"
    F3p5 = "3.5"
    F4p0 = "4.0"
    F4p5 = "4.5"
    F5p0 = "5.0"
    F5p6 = "5.6"
    F6p3 = "6.3"
    F7p1 = "7.1"
    F8p0 = "8.0"
    F9p0 = "9.0"
    F10 = "10"
    F11 = "11"
    F13 = "13"
    F14 = "14"
    F16 = "16"
    F18 = "18"
    F20 = "20"
    F22 = "22"
    F25 = "25"
    F29 = "29"
    F32 = "32"

class RcIso(str, Enum):
    Auto = "Auto"
    I100 = "100"
    I200 = "200"
    I400 = "400"
    I800 = "800"
    I1600 = "1600"
    I3200 = "3200"
    I6400 = "6400"
    I12800 = "12800"
    I25600 = "25600"

class RcWhiteBalance(str, Enum):
    Auto = "Auto"
    Sunny = "Sunny"
    Cloudy = "Cloudy"
    Shadow = "Shadow"
    Incandescent = "Incandescent"
    K2000 = "2000"
    K2050 = "2050"
    K2100 = "2100"
    K2150 = "2150"
    K2200 = "2200"
    K2250 = "2250"
    K2300 = "2300"
    K2350 = "2350"
    K2400 = "2400"
    K2450 = "2450"
    K2500 = "2500"
    K2550 = "2550"
    K2600 = "2600"
    K2650 = "2650"
    K2700 = "2700"
    K2750 = "2750"
    K2800 = "2800"
    K2850 = "2850"
    K2900 = "2900"
    K2950 = "2950"
    K3000 = "3000"
    K3100 = "3100"
    K3200 = "3200"
    K3300 = "3300"
    K3400 = "3400"
    K3500 = "3500"
    K3600 = "3600"
    K3700 = "3700"
    K3800 = "3800"
    K3900 = "3900"
    K4000 = "4000"
    K4200 = "4200"
    K4400 = "4400"
    K4600 = "4600"
    K4800 = "4800"
    K5000 = "5000"
    K5200 = "5200"
    K5400 = "5400"
    K5600 = "5600"
    K5800 = "5800"
    K6000 = "6000"
    K6200 = "6200"
    K6400 = "6400"
    K6600 = "6600"
    K6800 = "6800"
    K7000 = "7000"
    K7500 = "7500"
    K8000 = "8000"
    K8500 = "8500"
    K9000 = "9000"
    K9500 = "9500"
    K10000 = "10000"
    K10500 = "10500"
    K11000 = "11000"
    K11500 = "11500"

class RcShutterSpeed(str, Enum):
    # Confirmed live 2026-07-24 (accepted + echoed by metadata). These were missing from
    # the upstream bullbin mapping our list came from - the firmware has more values than
    # that map documented. NOTE: 1/3000s, 1/1700s, TIME2, TIME10 also exist as strings in
    # the firmware but did NOT take on hardware (metadata stayed put), so they are omitted.
    SF8000 = "1/8000s"
    SF6400 = "1/6400s"
    SF5000 = "1/5000s"
    Time = "TIME"
    Bulb = "BULB"
    S60 = "60s"
    S50 = "50s"
    S40 = "40s"
    S30 = "30s"
    S25 = "25s"
    S20 = "20s"
    S15 = "15s"
    S13 = "13s"
    S10 = "10s"
    S8 = "8s"
    S6 = "6s"
    S5 = "5s"
    S4 = "4s"
    S3p2 = "3.2s"
    S2p5 = "2.5s"
    S2 = "2s"
    S1p6 = "1.6s"
    S1p3 = "1.3s"
    S1 = "1s"
    SF1p3 = "1/1.3s"
    SF1p6 = "1/1.6s"
    SF2 = "1/2s"
    SF2p5 = "1/2.5s"
    SF3 = "1/3s"
    SF4 = "1/4s"
    SF5 = "1/5s"
    SF6 = "1/6s"
    SF8 = "1/8s"
    SF10 = "1/10s"
    SF13 = "1/13s"
    SF15 = "1/15s"
    SF20 = "1/20s"
    SF25 = "1/25s"
    SF30 = "1/30s"
    SF40 = "1/40s"
    SF50 = "1/50s"
    SF60 = "1/60s"
    SF80 = "1/80s"
    SF100 = "1/100s"
    SF125 = "1/125s"
    SF160 = "1/160s"
    SF200 = "1/200s"
    SF250 = "1/250s"
    SF320 = "1/320s"
    SF400 = "1/400s"
    SF500 = "1/500s"
    SF640 = "1/640s"
    SF800 = "1/800s"
    SF1000 = "1/1000s"
    SF1250 = "1/1250s"
    SF1600 = "1/1600s"
    SF2000 = "1/2000s"
    SF2500 = "1/2500s"
    SF3200 = "1/3200s"
    SF4000 = "1/4000s"

class RcColorStyle(str, Enum):
    Standard = "Standard"
    Portrait = "Portrait"
    Vivid = "Vivid"
    NaturalBW = "NaturalBW"
    HighContrastBW = "HContrastBW"

class RcEvOffset(str, Enum):
    N5p0 = "-5.0"
    N4p7 = "-4.7"
    N4p3 = "-4.3"
    N4p0 = "-4.0"
    N3p7 = "-3.7"
    N3p3 = "-3.3"
    N3p0 = "-3.0"
    N2p7 = "-2.7"
    N2p3 = "-2.3"
    N2p0 = "-2.0"
    N1p7 = "-1.7"
    N1p3 = "-1.3"
    N1p0 = "-1.0"
    N0p7 = "-0.7"
    N0p3 = "-0.3"
    Zero = "0.0"
    P0p3 = "0.3"
    P0p7 = "0.7"
    P1p0 = "1.0"
    P1p3 = "1.3"
    P1p7 = "1.7"
    P2p0 = "2.0"
    P2p3 = "2.3"
    P2p7 = "2.7"
    P3p0 = "3.0"
    P3p3 = "3.3"
    P3p7 = "3.7"
    P4p0 = "4.0"
    P4p3 = "4.3"
    P4p7 = "4.7"
    P5p0 = "5.0"
class RcVideoFormat(str, Enum):
    """Video resolution/frame-rate modes, sent as RCVideoFormatSet's "Resolution" parameter.

    All seven strings were read out of the firmware's .rodata and all seven were accepted by a
    real camera (2026-07-24); FHD_24 and FHD_30 were additionally verified end-to-end with
    ffprobe on the recorded files (24000/1001 and 30000/1001 respectively).

    NOTE: 4K_24 and FHD_24 are not offered anywhere in the camera's own menus and were never
    supported by the official app - they are only reachable through this command. There is no
    2K_24 or 2K_60 in the firmware. See 'fable research/rcvideoformatset-solved.md'.
    """
    UHD_30 = "4K_30"
    QHD_30 = "2K_30"
    FHD_60 = "FHD_60"
    FHD_30 = "FHD_30"
    FHD_24 = "FHD_24"
    # Confirmed live 2026-07-24: accepted AND echoed back by the live-view metadata.
    HD_60 = "720P_60"
    HD_30 = "720P_30"
    HD_24 = "720P_24"
    # SLOW MOTION. The camera captures ~240 fps and conforms it to a 30 fps file itself, so a
    # 3-second recording produced a 23-second, 690-frame 640x480 clip - about 8x slow motion,
    # verified with ffprobe. The YI M1 officially has no slow-motion mode at all; this was
    # sitting in the firmware the whole time.
    VGA_240 = "VGA_240"
    # DELIBERATELY ABSENT - accepted by the command (HTTP 200) but NOT applied by the camera,
    # which reverts to a working mode: "2880_24"/"1920_24" (metadata never changes) and
    # "4K_24"/"4K_30_LOW" (revert to 4K_30 on record, user-verified on hardware 2026-07-24).
    # 4K is locked to 30p. "VGA" (no frame rate) returns a plain 404. All Xacti-platform leftovers.


class RcOnOff(str, Enum):
    """Shared value type for RCEisSwitchSet / RCVASwitchSet / RCVANoiseReduceSet.

    UPPERCASE, and that matters: the strings live at 0x1540f0 and 0x1540f4 in the firmware and
    the handlers compare against them directly. "On"/"Off" would 404 - which is exactly the trap
    that kept these four commands filed as "dead" for years.
    """
    On = "ON"
    Off = "OFF"


class RcAudioVolume(str, Enum):
    """Microphone level for RCVAVolSet - a PERCENTAGE, 1..100.

    Scale measured on the camera 2026-07-26 (probe_mic_volume_scale.py): every value from 1 to
    100 is echoed back verbatim in the VAVol metadata field, so it really is percent and not the
    small level scale it first looked like. "0" is the one value the camera REJECTS - it keeps
    the previous setting. Use the separate Audio on/off switch (RCVASwitchSet) to mute.

    Worth knowing: the camera's own default sat at 2 (i.e. 2%), which is effectively silent and
    is what produced a "video recorded with no sound" report. Anything below ~25 is very quiet."""
    V10 = "10"
    V25 = "25"
    V50 = "50"
    V75 = "75"
    V100 = "100"
