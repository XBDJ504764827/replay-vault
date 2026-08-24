// events.sp - replay landed -> build key -> stage -> upload
// Runs: via GOKZ_RP_OnReplaySaved (all ReplayType_Run, including temp). Jumps/Cheaters: via scan fallback.

void RV_OnMapStart()
{
    RV_OnMapStart_Helpers();
}

void RV_OnReplaySaved(int client, int replayType, const char[] map,
    int course, int timeType, float time, const char[] filePath, bool tempReplay)
{
    // Only runs use this forward in current gokz-replays (recording.sp SaveRecordingOfRun).
    // We upload ALL runs that hit disk, including tempRuns (tempReplay==true).
    if (replayType != ReplayType_Run) return;
    if (filePath[0] == '\0') return;
    // filePath may be "" if gokz-replays failed to save; check existence via staged copy later
    RV_HandleRun(client, map, course, timeType, time, filePath);
}

void RV_HandleRun(int client, const char[] map, int course, int timeType, float time, const char[] filePath)
{
    if (!RV_CanUpload()) return;

    // Normalize map lower
    char mapLower[64];
    if (map[0] != '\0') RV_ToLower(map, mapLower, sizeof(mapLower));
    else strcopy(mapLower, sizeof(mapLower), gC_CurrentMap);
    if (mapLower[0] == '\0')
    {
        char cur[64];
        GetCurrentMapDisplayName(cur, sizeof(cur));
        RV_ToLower(cur, mapLower, sizeof(mapLower));
    }

    // Validate course
    if (course < 0 || course >= GOKZ_MAX_COURSES)
    {
        LogError("[replay-vault] Invalid course %d for run %s, skip", course, filePath);
        return;
    }

    // Mode from client's current mode (most reliable for key); fallback to forward style if needed
    int mode = Mode_KZTimer;
    if (IsValidClient(client)) mode = GOKZ_GetCoreOption(client, Option_Mode);
    if (mode < 0 || mode >= MODE_COUNT) mode = Mode_KZTimer;

    char courseStr[16], modeStr[16], timetypeStr[16];
    RV_CourseToString(course, courseStr, sizeof(courseStr));
    RV_ModeToString(mode, modeStr, sizeof(modeStr));
    RV_TimeTypeToString(timeType, timetypeStr, sizeof(timetypeStr));

    char steamid64[32];
    bool hasSid = false;
    if (IsValidClient(client)) hasSid = RV_GetSteamID64(client, steamid64, sizeof(steamid64));
    if (!hasSid)
    {
        // Try to parse from filePath fallback or skip
        LogError("[replay-vault] Cannot get SteamID64 for client %d course %d map %s, skip upload", client, course, mapLower);
        return;
    }

    char date[RV_MAX_DATE_LENGTH];
    RV_FormatDate(GetTime(), date, sizeof(date));

    char uuid[64];
    RV_GenerateUUID(uuid, sizeof(uuid));

    int timeMs = RoundToNearest(time * 1000.0);

    char key[RV_MAX_KEY_LENGTH];
    RV_BuildRunKey(mapLower, courseStr, steamid64, modeStr, timetypeStr, date, uuid, key, sizeof(key));

    char stagingPath[PLATFORM_MAX_PATH];
    if (!RV_StageFile(filePath, uuid, stagingPath, sizeof(stagingPath)))
    {
        LogError("[replay-vault] Failed to stage %s -> %s", filePath, stagingPath);
        return;
    }

    int userId = IsValidClient(client) ? GetClientUserId(client) : 0;
    RV_UploadFile(stagingPath, key, uuid, mapLower, course, steamid64, modeStr, timetypeStr, date, timeMs, userId);
}

// Jumps fallback: GOKZ_DB_OnJumpstatPB is called on new jump PB; gokz-replays saves jump replay 2s later.
// We delay scan to catch the file.
void RV_OnJumpstatPB(int client, int jumptype, int mode, float distance, int block, int strafes, float sync, float pre, float max, int airtime)
{
    if (!RV_CanUpload()) return;
    if (!IsValidClient(client)) return;
    // Delay 2.5s to let recording.sp SaveRecordingOfJump finish (RP_PLAYBACK_BREATHER_TIME=2.0)
    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));
    dp.WriteCell(jumptype);
    dp.WriteCell(mode);
    dp.WriteCell(block);
    CreateTimer(2.5, Timer_ScanJump, dp, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ScanJump(Handle timer, DataPack dp)
{
    dp.Reset();
    int userId = dp.ReadCell();
    int jumptype = dp.ReadCell();
    int mode = dp.ReadCell();
    int block = dp.ReadCell();
    delete dp;

    int client = GetClientOfUserId(userId);
    if (!IsValidClient(client)) return Plugin_Stop;
    if (!RV_CanUpload()) return Plugin_Stop;

    char steamid64[32];
    if (!RV_GetSteamID64(client, steamid64, sizeof(steamid64))) return Plugin_Stop;

    char mapLower[64];
    strcopy(mapLower, sizeof(mapLower), gC_CurrentMap);
    if (mapLower[0] == '\0')
    {
        char cur[64];
        GetCurrentMapDisplayName(cur, sizeof(cur));
        RV_ToLower(cur, mapLower, sizeof(mapLower));
    }

    // Scan data/gokz-replays/_jumps/<accountID>/ for newest file matching this jump
    int accountID = GetSteamAccountID(client);
    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), "data/gokz-replays/_jumps/%d", accountID);
    if (!DirExists(dir)) return Plugin_Stop;

    char latestPath[PLATFORM_MAX_PATH];
    int latestTime = 0;
    DirectoryListing dl = OpenDirectory(dir);
    if (dl == null) return Plugin_Stop;
    char entry[PLATFORM_MAX_PATH];
    FileType ftype;
    while (dl.GetNext(entry, sizeof(entry), ftype))
    {
        if (ftype != FileType_File) continue;
        // Also check blocks subdirectory
        if (StrEqual(entry, ".") || StrEqual(entry, "..")) continue;
        char full[PLATFORM_MAX_PATH];
        FormatEx(full, sizeof(full), "%s/%s", dir, entry);
        // If entry is directory "blocks", scan inside
        if (DirExists(full))
        {
            DirectoryListing dl2 = OpenDirectory(full);
            if (dl2 != null)
            {
                char e2[PLATFORM_MAX_PATH];
                FileType ft2;
                while (dl2.GetNext(e2, sizeof(e2), ft2))
                {
                    if (ft2 != FileType_File) continue;
                    char full2[PLATFORM_MAX_PATH];
                    FormatEx(full2, sizeof(full2), "%s/%s", full, e2);
                    int mtime = GetFileTime(full2, FileTime_LastChange);
                    if (mtime > latestTime)
                    {
                        latestTime = mtime;
                        strcopy(latestPath, sizeof(latestPath), full2);
                    }
                }
                delete dl2;
            }
            continue;
        }
        int mtime = GetFileTime(full, FileTime_LastChange);
        if (mtime > latestTime)
        {
            latestTime = mtime;
            strcopy(latestPath, sizeof(latestPath), full);
        }
    }
    delete dl;

    if (latestPath[0] == '\0') return Plugin_Stop;
    // Only upload if file is recent (within 10s)
    if (GetTime() - latestTime > 10) return Plugin_Stop;

    char modeStr[16];
    RV_ModeToString(mode, modeStr, sizeof(modeStr));

    // Jump type id -> name (reuse gokz jumpstats names if available, fallback to id string)
    char jumpName[32];
    FormatEx(jumpName, sizeof(jumpName), "%d", jumptype);
    // Try to resolve via gokz jump type names if plugin exposes them; keep id string otherwise
    // For key we lower it anyway

    char date[RV_MAX_DATE_LENGTH];
    RV_FormatDate(GetTime(), date, sizeof(date));
    char uuid[64];
    RV_GenerateUUID(uuid, sizeof(uuid));

    char key[RV_MAX_KEY_LENGTH];
    // Check if path contains /blocks/ to extract block number from filename
    int actualBlock = block;
    if (StrContains(latestPath, "/blocks/") != -1 && actualBlock == 0)
    {
        // Try to parse block from filename like "1_240_KZT_NRM.replay" - second part is block
        char fname[PLATFORM_MAX_PATH];
        int lastSlash = -1;
        for (int i = 0; latestPath[i] != '\0'; i++) if (latestPath[i] == '/') lastSlash = i;
        strcopy(fname, sizeof(fname), latestPath[lastSlash + 1]);
        char parts[4][32];
        if (ExplodeString(fname, "_", parts, sizeof(parts), sizeof(parts[])) >= 2)
            actualBlock = StringToInt(parts[1]);
    }

    RV_BuildJumpKey(mapLower, steamid64, modeStr, jumpName, actualBlock, date, uuid, key, sizeof(key));

    char stagingPath[PLATFORM_MAX_PATH];
    if (!RV_StageFile(latestPath, uuid, stagingPath, sizeof(stagingPath)))
    {
        LogError("[replay-vault] Failed to stage jump %s", latestPath);
        return Plugin_Stop;
    }

    RV_UploadFile(stagingPath, key, uuid, mapLower, -1, steamid64, modeStr, "jump", date, 0, userId);
    return Plugin_Stop;
}

void RV_OnCheaterSuspected(int client, int reason)
{
    if (!RV_CanUpload()) return;
    if (!IsValidClient(client)) return;
    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));
    dp.WriteCell(reason);
    CreateTimer(1.0, Timer_ScanCheater, dp, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ScanCheater(Handle timer, DataPack dp)
{
    dp.Reset();
    int userId = dp.ReadCell();
    int reason = dp.ReadCell();
    delete dp;

    int client = GetClientOfUserId(userId);
    // Client may have been kicked; still try by userId fallback via accountID scan
    char steamid64[32];
    int accountID = 0;
    if (IsValidClient(client))
    {
        if (!RV_GetSteamID64(client, steamid64, sizeof(steamid64))) return Plugin_Stop;
        accountID = GetSteamAccountID(client);
    }
    else
    {
        // Cannot resolve without client; skip
        return Plugin_Stop;
    }

    char mapLower[64];
    strcopy(mapLower, sizeof(mapLower), gC_CurrentMap);
    if (mapLower[0] == '\0')
    {
        char cur[64];
        GetCurrentMapDisplayName(cur, sizeof(cur));
        RV_ToLower(cur, mapLower, sizeof(mapLower));
    }

    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), "data/gokz-replays/_cheaters");
    if (!DirExists(dir)) return Plugin_Stop;

    // Find newest file for this accountID prefix
    char latestPath[PLATFORM_MAX_PATH];
    int latestTime = 0;
    char prefix[32];
    FormatEx(prefix, sizeof(prefix), "%d_", accountID);

    DirectoryListing dl = OpenDirectory(dir);
    if (dl == null) return Plugin_Stop;
    char entry[PLATFORM_MAX_PATH];
    FileType ftype;
    while (dl.GetNext(entry, sizeof(entry), ftype))
    {
        if (ftype != FileType_File) continue;
        if (StrContains(entry, prefix) != 0) continue;
        char full[PLATFORM_MAX_PATH];
        FormatEx(full, sizeof(full), "%s/%s", dir, entry);
        int mtime = GetFileTime(full, FileTime_LastChange);
        if (mtime > latestTime)
        {
            latestTime = mtime;
            strcopy(latestPath, sizeof(latestPath), full);
        }
    }
    delete dl;
    if (latestPath[0] == '\0') return Plugin_Stop;
    if (GetTime() - latestTime > 10) return Plugin_Stop;

    int mode = Mode_KZTimer;
    if (IsValidClient(client)) mode = GOKZ_GetCoreOption(client, Option_Mode);
    char modeStr[16];
    RV_ModeToString(mode, modeStr, sizeof(modeStr));

    char reasonStr[64];
    FormatEx(reasonStr, sizeof(reasonStr), "%d", reason);

    char date[RV_MAX_DATE_LENGTH];
    RV_FormatDate(GetTime(), date, sizeof(date));
    char uuid[64];
    RV_GenerateUUID(uuid, sizeof(uuid));

    char key[RV_MAX_KEY_LENGTH];
    RV_BuildCheaterKey(mapLower, steamid64, modeStr, reasonStr, date, uuid, key, sizeof(key));

    char stagingPath[PLATFORM_MAX_PATH];
    if (!RV_StageFile(latestPath, uuid, stagingPath, sizeof(stagingPath)))
    {
        LogError("[replay-vault] Failed to stage cheater %s", latestPath);
        return Plugin_Stop;
    }

    RV_UploadFile(stagingPath, key, uuid, mapLower, -1, steamid64, modeStr, "cheat", date, 0, userId);
    return Plugin_Stop;
}

bool IsValidClient(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}
