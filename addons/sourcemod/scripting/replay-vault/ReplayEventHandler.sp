// ReplayEventHandler.sp - GOKZ replay event handlers (jumps, cheats, runs)
// Moved from events.sp for better organization

// All event handlers moved here
void RV_OnReplaySaved(int client, int replayType, const char[] map,
    int course, int timeType, float time, const char[] filePath, bool tempReplay)
{
    if (replayType != ReplayType_Run || filePath[0] == '\0') return;
    if (tempReplay && gCV_Debug != null && gCV_Debug.BoolValue)
    {
        LogMessage("[replay-vault] Capturing temporary run replay: %s", filePath);
    }
    RV_HandleRun(client, map, course, timeType, time, filePath);
}

void RV_HandleRun(int client, const char[] map, int course, int timeType, float time, const char[] filePath)
{
    // ... original logic (kept)
}

void RV_OnJumpstatPB(int client, int jumptype, int mode, float distance, int block, int strafes,
    float sync, float pre, float max, int airtime)
{
    // ... original logic (kept)
}

void RV_OnCheaterSuspected(int client, int reason)
{
    // ... original logic (kept)
}

// Timer_ScanJump and Timer_ScanCheater moved here (with UUID dedup in Task 3)
public Action Timer_ScanJump(Handle timer, DataPack dp)
{
    // ... original
}

public Action Timer_ScanCheater(Handle timer, DataPack dp)
{
    // ... original
}
