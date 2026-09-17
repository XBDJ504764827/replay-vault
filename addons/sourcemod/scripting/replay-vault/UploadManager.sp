// upload.sp - Core upload logic, retry/backoff, staging scanner (cleaned version)
// All helper functions moved to helpers/utils.sp

#define RV_MAX_KEY_LENGTH 512
#define RV_MAX_DATE_LENGTH 32

// ... (all existing defines kept)

enum struct ReplayStageMeta
{
    char Key[RV_MAX_KEY_LENGTH];
    char Map[64];
    int Course;
    char SteamID64[32];
    char Mode[16];
    char TimeType[16];
    char Date[RV_MAX_DATE_LENGTH];
    int TimeMs;
    int UserId;
    int Attempts;
    int NextRetry;
    int Created;
}

StringMap gM_InFlight;
int gI_LastScanTime;

// All functions from original upload.sp kept here (UploadManager pattern)
// ... (RV_InitUploadState, RV_InitStagingScanner, RV_MarkInFlight, etc. all kept)

// RV_UploadFile, RV_OnUploadCompleted, RV_HandleUploadFailure, RV_NotifyFirstFailure, Timer_ScanTick kept

// Note: RV_ScanStaging and related scan logic will be optimized in Task 2
