// events.sp - replay landed -> build key -> stage -> upload
// Runs: via GOKZ_RP_OnReplaySaved (all ReplayType_Run, including temp). Jumps/Cheaters: via scan fallback.

void RV_OnMapStart()
{
    RV_OnMapStart_Helpers();
}

void RV_OnReplaySaved(int client, int replayType, const char[] map,
    int course, int timeType, float time, const char[] filePath, bool tempReplay)
{
    if (tempReplay) {}
    // Only runs use this forward in current gokz-replays (recording.sp SaveRecordingOfRun).
    // We upload ALL runs that hit disk, including tempRuns (tempReplay==true).
    if (replayType != ReplayType_Run) return;
    if (filePath[0] == '\0') return;
    RV_HandleRun(client, map, course, timeType, time, filePath);
}

void RV_HandleRun(int client, const char[] map, int course, int timeType, float time, const char[] filePath)
{
    if (!RV_CanUpload()) return;

    char mapLower[64];
    if (map[0] != '\0')
    {
        RV_SanitizeMap(map, mapLower, sizeof(mapLower));
    }
    else
    {
        strcopy(mapLower, sizeof(mapLower), gC_CurrentMap);
    }
    if (mapLower[0] == '\0')
    {
        char cur[64];
        GetCurrentMapDisplayName(cur, sizeof(cur));
        RV_SanitizeMap(cur, mapLower, sizeof(mapLower));
    }

    if (course < 0 || course >= GOKZ_MAX_COURSES)
    {
        LogError("[replay-vault] Invalid course %d for run %s, skip", course, filePath);
        return;
    }

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

void RV_OnJumpstatPB(int client, int jumptype, int mode, float distance, int block, int strafes, float sync, float pre, float max, int airtime)
{
    if (distance < -1.0) LogMessage("[replay-vault] dbg jump distance %f", distance);
    if (strafes < -1) LogMessage("[replay-vault] dbg strafes %d", strafes);
    if (sync < -1.0) LogMessage("[replay-vault] dbg sync %f", sync);
    if (pre < -1.0) LogMessage("[replay-vault] dbg pre %f", pre);
    if (max < -1.0) LogMessage("[replay-vault] dbg max %f", max);
    if (airtime < -1) LogMessage("[replay-vault] dbg airtime %d", airtime);
    if (!RV_CanUpload()) return;
    if (!IsValidClient(client)) return;
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
        RV_SanitizeMap(cur, mapLower, sizeof(mapLower));
    }

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
        if (StrEqual(entry, ".") || StrEqual(entry, "..")) continue;
        char full[PLATFORM_MAX_PATH];
        FormatEx(full, sizeof(full), "%s/%s", dir, entry);
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
                    if (StrEqual(e2, ".") || StrEqual(e2, "..")) continue;
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
        if (ftype != FileType_File) continue;
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

    char modeStr[16];
    RV_ModeToString(mode, modeStr, sizeof(modeStr));

    // Prefer human-readable jump type key (longjump/bhop/...) for key readability
    char jumpName[32];
    if (jumptype >= 0 && jumptype < JUMPTYPE_COUNT)
        strcopy(jumpName, sizeof(jumpName), gC_JumpTypeKeys[jumptype]);
    else
        FormatEx(jumpName, sizeof(jumpName), "%d", jumptype);

    char date[RV_MAX_DATE_LENGTH];
    RV_FormatDate(GetTime(), date, sizeof(date));
    char uuid[64];
    RV_GenerateUUID(uuid, sizeof(uuid));

    char key[RV_MAX_KEY_LENGTH];
    int actualBlock = block;
    if (StrContains(latestPath, "/blocks/") != -1 && actualBlock == 0)
    {
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
    int reasonInt = dp.ReadCell();
    ACReason reason = view_as<ACReason>(reasonInt);
    delete dp;

    int client = GetClientOfUserId(userId);
    char steamid64[32];
    int accountID = 0;
    if (IsValidClient(client))
    {
        if (!RV_GetSteamID64(client, steamid64, sizeof(steamid64))) return Plugin_Stop;
        accountID = GetSteamAccountID(client);
    }
    else
    {
        return Plugin_Stop;
    }

    char mapLower[64];
    strcopy(mapLower, sizeof(mapLower), gC_CurrentMap);
    if (mapLower[0] == '\0')
    {
        char cur[64];
        GetCurrentMapDisplayName(cur, sizeof(cur));
        RV_SanitizeMap(cur, mapLower, sizeof(mapLower));
    }

    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), "data/gokz-replays/_cheaters");
    if (!DirExists(dir)) return Plugin_Stop;

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
    if (reason >= ACReason_BhopMacro && reason < ACREASON_COUNT)
        strcopy(reasonStr, sizeof(reasonStr), gC_ACReasons[reason]);
    else
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
