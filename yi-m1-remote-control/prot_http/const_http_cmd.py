from enum import Enum

class YiHttpCmdId(str, Enum):
    CMD_FILE_LIST               = "GetFileList"         # Done
    CMD_FILE_INFO               = "GetFileInfo"
    CMD_FILE_DELETE             = "DeleteFile"          # Done
    CMD_FILE_GET                = "GetFile"             # Done

    CMD_STATUS_CHECK            = "CheckPreUpdate"
    CMD_STATUS_GET              = "GetCameraStatus"

    CMD_FIRMWARE_UPLOAD_CAM     = "UpdateFW"
    CMD_FIRMWARE_UPLOAD_LENS    = "UpdateLenFW"
    
    CMD_MASTERGUIDE_LIST        = "GetMLFileList"
    CMD_MASTERGUIDE_INFO        = "GetMLFileInfo"
    CMD_MASTERGUIDE_DELETE      = "DeleteMLFile"
    CMD_MASTERGUIDE_UPLOAD      = "UploadML"

    CMD_RC_START                = "RCStartRemoteCtl"    # Done
    CMD_RC_STOP                 = "RCStopRemoteCtl"     # Done

    CMD_RC_SET_EXPOSURE_MODE    = "RCSwitchDialMode"    # Done
    CMD_RC_SET_METERING_MODE    = "RCMeteringModeSet"   # Done
    CMD_RC_SET_FOCUS_MODE       = "RCFocusModeSet"      # Done
    CMD_RC_SET_IMAGE_QUALITY    = "RCImageQualitySet"   # Done
    CMD_RC_SET_IMAGE_ASPECT     = "RCImageAspect"       # Done
    CMD_RC_SET_IMAGE_FORMAT     = "RCFileFormatSet"     # Done
    CMD_RC_SET_DRIVE_MODE       = "RCDriveModeSet"      # Done
    CMD_RC_SET_FNUMBER          = "RCFNSet"             # Done
    CMD_RC_SET_SHUTTER_SPEED    = "RCShutterSpeedSet"   # Done
    CMD_RC_SET_EV               = "RCEVSet"             # Done
    CMD_RC_SET_ISO              = "RCISOSet"            # Done
    CMD_RC_SET_WB               = "RCWBSet"             # Done
    CMD_RC_SET_COLOR_MODE       = "RCChooseColorMode"   # Done
    CMD_RC_ADJUST_MF            = "RCMFAdjust"
    CMD_RC_DELAY_SHOOT_COUNT    = "RCDShootCntSet"

    CMD_RC_FOCUS                = "RCDoFocus"           # Done
    CMD_RC_SHOOT                = "RCDoShooting"        # Done

    # Confirmed working 2026-07-02 against firmware 3.2-int (not part of upstream bullbin mapping).
    CMD_VIDEO_RECORDING_START   = "VideoRecordingStart"  # Confirmed: actually starts recording
    CMD_VIDEO_RECORDING_STOP    = "VideoRecordingStop"   # Confirmed: actually stops recording

    # SOLVED 2026-07-24 - see 'fable research/rcvideoformatset-solved.md'.
    # This was long recorded as "returns 404, not reachable". That was WRONG: the parameter key
    # is "Resolution" (NOT "VideoFormat"/"Value"/"Mode", the three names previously guessed).
    # Recovered by decompiling the handler at 0x0015641c, whose key string lives at 0x006b8416,
    # then confirmed on hardware and verified with ffprobe on the recorded files. The old false
    # negative happened because a command sent WITHOUT its required parameter returns the same
    # 404 as a nonexistent command - so probing wrong key names looked like "not routed".
    CMD_RC_SET_VIDEO_FORMAT     = "RCVideoFormatSet"     # Confirmed: key is "Resolution"

    # Same family, handlers present in firmware, parameter keys not yet recovered - these still
    # 404 for us, most likely for the same reason (wrong key name), NOT because they are unwired.
    CMD_RC_SET_VA_SWITCH        = "RCVASwitchSet"        # audio on/off - key unknown
    CMD_RC_SET_VA_VOLUME        = "RCVAVolSet"           # key is probably "Vol" (0x6b8421), untested
    CMD_RC_SET_VA_NOISE_REDUCE  = "RCVANoiseReduceSet"   # key unknown
    CMD_RC_SET_EIS_SWITCH       = "RCEisSwitchSet"       # stabilisation - key unknown
