// events.sp - replay saved -> stage -> asynchronous upload

#define RV_REPLAY_SCAN_DELAY 2.5
#define RV_REPLAY_SCAN_RETRY_DELAY 0.75
#define RV_REPLAY_SCAN_MAX_ATTEMPTS 3
#define RV_REPLAY_MAX_AGE 15

void RV_InitEventState()
{
    if (gM_CapturedReplays == null)
    {
        gM_CapturedReplays = new StringMap();
    }
}

void RV_ResetEventState()
{
    RV_InitEventState();
    gM_CapturedReplays.Clear();
}

bool RV_GetReplaySignature(const char[] path, int &modified, int &size)
{
    modified = GetFileTime(path, FileTime_LastChange);
    size = FileSize(path);
    return modified >= 0 && size > 0;
}

bool RV_MarkReplayCaptured(const char[] path, int expectedModified = -1, int expectedSize = -1)
{
    int modified, size;
    if (!RV_GetReplaySignature(path, modified, size)) return false;
    if (expectedModified >= 0 && (modified != expectedModified || size != expectedSize)) return false;

    char fingerprint[PLATFORM_MAX_PATH + 32];
    FormatEx(fingerprint, sizeof(fingerprint), "%s|%d|%d", path, modified, size);
    RV_InitEventState();
    if (gM_CapturedReplays.ContainsKey(fingerprint)) return false;
    return gM_CapturedReplays.SetValue(fingerprint, 1, false);
}

void RV_OnMapStart()
{
    RV_ResetEventState();
    RV_OnMapStart_Helpers();
}

void RV_GetEventMap(const char[] map, char[] output, int maxlen)
{
    if (map[0] != '\0')
    {
        RV_SanitizeMap(map, output, maxlen);
    }
    else
    {
        strcopy(output, maxlen, gC_CurrentMap);
    }

    if (output[0] == '\0')
    {
        char currentMap[64];
        GetCurrentMapDisplayName(currentMap, sizeof(currentMap));
        RV_SanitizeMap(currentMap, output, maxlen);
    }
}

int RV_GetClientMode(int client, int fallback)
{
    if (!IsValidClient(client)) return fallback;
    if (GetFeatureStatus(FeatureType_Native, "GOKZ_GetOption") != FeatureStatus_Available)
    {
        return fallback;
    }

    int mode = GOKZ_GetCoreOption(client, Option_Mode);
    if (mode < 0 || mode >= MODE_COUNT) return fallback;
    return mode;
}

int RV_GetRunMode(int client, const char[] filePath)
{
    char fileName[PLATFORM_MAX_PATH];
    RV_GetFileName(filePath, fileName, sizeof(fileName));

    int ignoredCourse;
    char modeShort[16], ignoredTimeType[16];
    if (RV_ParseRunFileNameLocal(fileName, ignoredCourse, modeShort, sizeof(modeShort),
        ignoredTimeType, sizeof(ignoredTimeType)))
    {
        int parsedMode = RV_ModeFromString(modeShort);
        if (parsedMode >= 0) return parsedMode;
    }

    return RV_GetClientMode(client, Mode_KZTimer);
}

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
    if (!RV_CanUpload()) return;

    char mapLower[64];
    RV_GetEventMap(map, mapLower, sizeof(mapLower));

    if (course < 0 || course >= GOKZ_MAX_COURSES)
    {
        LogError("[replay-vault] Invalid course %d for run %s, skip", course, filePath);
        return;
    }

    int resolvedTimeType = timeType;
    if (resolvedTimeType < 0 || resolvedTimeType >= TIMETYPE_COUNT)
    {
        resolvedTimeType = TimeType_Pro;
    }

    int mode = RV_GetRunMode(client, filePath);
    char courseStr[16], modeStr[16], timetypeStr[16];
    RV_CourseToString(course, courseStr, sizeof(courseStr));
    RV_ModeToString(mode, modeStr, sizeof(modeStr));
    RV_TimeTypeToString(resolvedTimeType, timetypeStr, sizeof(timetypeStr));

    char steamid64[32];
    if (!IsValidClient(client) || !RV_GetSteamID64(client, steamid64, sizeof(steamid64)))
    {
        LogError("[replay-vault] Cannot get SteamID64 for client %d course %d map %s, skip upload",
            client, course, mapLower);
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
        LogError("[replay-vault] Failed to stage run %s", filePath);
        return;
    }

    int userId = GetClientUserId(client);
    RV_UploadFile(stagingPath, key, uuid, mapLower, course, steamid64, modeStr,
        timetypeStr, date, timeMs, userId);
}

void RV_ScheduleJumpScan(int userId, int accountID, const char[] steamid64, const char[] map,
    int jumptype, int mode, int block, int eventTime, int baselineTime, int baselineSize, int attempt)
{
    DataPack dp = new DataPack();
    dp.WriteCell(userId);
    dp.WriteCell(accountID);
    dp.WriteString(steamid64);
    dp.WriteString(map);
    dp.WriteCell(jumptype);
    dp.WriteCell(mode);
    dp.WriteCell(block);
    dp.WriteCell(eventTime);
    dp.WriteCell(baselineTime);
    dp.WriteCell(baselineSize);
    dp.WriteCell(attempt);

    Handle timer = CreateTimer(attempt == 0 ? RV_REPLAY_SCAN_DELAY : RV_REPLAY_SCAN_RETRY_DELAY,
        Timer_ScanJump, dp, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
    if (timer == null)
    {
        delete dp;
        LogError("[replay-vault] Failed to schedule jump replay scan");
    }
}

void RV_OnJumpstatPB(int client, int jumptype, int mode, float distance, int block, int strafes,
    float sync, float pre, float max, int airtime)
{
    if (!RV_CanUpload() || !IsValidClient(client)) return;

    if (gCV_Debug != null && gCV_Debug.BoolValue)
    {
        LogMessage("[replay-vault] Jump PB client=%d type=%d distance=%.3f block=%d strafes=%d sync=%.3f pre=%.3f max=%.3f airtime=%d",
            client, jumptype, distance, block, strafes, sync, pre, max, airtime);
    }

    char steamid64[32];
    if (!RV_GetSteamID64(client, steamid64, sizeof(steamid64))) return;
    int accountID = GetSteamAccountID(client);
    if (accountID <= 0) return;

    int resolvedMode = mode;
    if (resolvedMode < 0 || resolvedMode >= MODE_COUNT)
    {
        resolvedMode = RV_GetClientMode(client, Mode_KZTimer);
    }
    if (block < 0) block = 0;

    char map[64];
    RV_GetEventMap("", map, sizeof(map));
    char sourcePath[PLATFORM_MAX_PATH];
    RV_BuildJumpSourcePath(accountID, jumptype, resolvedMode, block, sourcePath, sizeof(sourcePath));
    int baselineTime = -1, baselineSize = -1;
    RV_GetReplaySignature(sourcePath, baselineTime, baselineSize);
    RV_ScheduleJumpScan(GetClientUserId(client), accountID, steamid64, map,
        jumptype, resolvedMode, block, GetTime(), baselineTime, baselineSize, 0);
}

void RV_BuildJumpSourcePath(int accountID, int jumptype, int mode, int block,
    char[] output, int maxlen)
{
    char modeShort[16];
    if (mode < 0 || mode >= MODE_COUNT)
    {
        output[0] = '\0';
        return;
    }
    strcopy(modeShort, sizeof(modeShort), gC_ModeNamesShort[mode]);
    char styleShort[16];
    strcopy(styleShort, sizeof(styleShort), gC_StyleNamesShort[Style_Normal]);
    if (block > 0)
    {
        BuildPath(Path_SM, output, maxlen, "%s/%d/%s/%d_%d_%s_%s.replay",
            RP_DIRECTORY_JUMPS, accountID, RP_DIRECTORY_BLOCKJUMPS, jumptype, block, modeShort, styleShort);
    }
    else
    {
        BuildPath(Path_SM, output, maxlen, "%s/%d/%d_%s_%s.replay",
            RP_DIRECTORY_JUMPS, accountID, jumptype, modeShort, styleShort);
    }
}

public Action Timer_ScanJump(Handle timer, DataPack dp)
{
    dp.Reset();
    int userId = dp.ReadCell();
    int accountID = dp.ReadCell();
    char steamid64[32], map[64];
    dp.ReadString(steamid64, sizeof(steamid64));
    dp.ReadString(map, sizeof(map));
    int jumptype = dp.ReadCell();
    int mode = dp.ReadCell();
    int block = dp.ReadCell();
    int eventTime = dp.ReadCell();
    int baselineTime = dp.ReadCell();
    int baselineSize = dp.ReadCell();
    int attempt = dp.ReadCell();

    if (!RV_CanUpload()) return Plugin_Stop;

    char sourcePath[PLATFORM_MAX_PATH];
    RV_BuildJumpSourcePath(accountID, jumptype, mode, block, sourcePath, sizeof(sourcePath));
    int sourceModified, sourceSize;
    bool sourceReady = RV_GetReplaySignature(sourcePath, sourceModified, sourceSize)
        && sourceModified >= eventTime - 1
        && !(sourceModified == baselineTime && sourceSize == baselineSize)
        && GetTime() - sourceModified <= RV_REPLAY_MAX_AGE;
    if (sourcePath[0] == '\0' || !sourceReady)
    {
        if (attempt < RV_REPLAY_SCAN_MAX_ATTEMPTS)
        {
            RV_ScheduleJumpScan(userId, accountID, steamid64, map, jumptype, mode, block, eventTime,
                baselineTime, baselineSize, attempt + 1);
        }
        else if (gCV_Debug != null && gCV_Debug.BoolValue)
        {
            LogMessage("[replay-vault] Jump replay was not found after retries: %s", sourcePath);
        }
        return Plugin_Stop;
    }

    char modeStr[16], jumpName[32], date[RV_MAX_DATE_LENGTH], uuid[64], key[RV_MAX_KEY_LENGTH];
    RV_ModeToString(mode, modeStr, sizeof(modeStr));
    RV_JumpTypeToString(jumptype, jumpName, sizeof(jumpName));
    RV_FormatDate(GetTime(), date, sizeof(date));
    RV_GenerateUUID(uuid, sizeof(uuid));
    RV_BuildJumpKey(map, steamid64, modeStr, jumpName, block, date, uuid, key, sizeof(key));

    char stagingPath[PLATFORM_MAX_PATH];
    if (!RV_StageFile(sourcePath, uuid, stagingPath, sizeof(stagingPath)))
    {
        LogError("[replay-vault] Failed to stage jump %s", sourcePath);
        return Plugin_Stop;
    }

    if (!RV_MarkReplayCaptured(sourcePath, sourceModified, sourceSize))
    {
        RV_DeleteStagingFile(stagingPath);
        return Plugin_Stop;
    }

    RV_UploadFile(stagingPath, key, uuid, map, -1, steamid64, modeStr,
        "jump", date, 0, userId);
    return Plugin_Stop;
}

void RV_ScheduleCheaterScan(int userId, int accountID, const char[] steamid64, const char[] map,
    int mode, int reason, int eventTime, int attempt)
{
    DataPack dp = new DataPack();
    dp.WriteCell(userId);
    dp.WriteCell(accountID);
    dp.WriteString(steamid64);
    dp.WriteString(map);
    dp.WriteCell(mode);
    dp.WriteCell(reason);
    dp.WriteCell(eventTime);
    dp.WriteCell(attempt);

    Handle timer = CreateTimer(attempt == 0 ? 1.0 : RV_REPLAY_SCAN_RETRY_DELAY,
        Timer_ScanCheater, dp, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
    if (timer == null)
    {
        delete dp;
        LogError("[replay-vault] Failed to schedule cheater replay scan");
    }
}

void RV_OnCheaterSuspected(int client, int reason)
{
    if (!RV_CanUpload() || !IsValidClient(client)) return;

    char steamid64[32];
    if (!RV_GetSteamID64(client, steamid64, sizeof(steamid64))) return;
    int accountID = GetSteamAccountID(client);
    if (accountID <= 0) return;

    char map[64];
    RV_GetEventMap("", map, sizeof(map));
    int mode = RV_GetClientMode(client, Mode_KZTimer);
    RV_ScheduleCheaterScan(GetClientUserId(client), accountID, steamid64, map,
        mode, reason, GetTime(), 0);
}

bool RV_FindCheaterReplay(int accountID, const char[] map, int mode, int eventTime,
    char[] output, int maxlen)
{
    output[0] = '\0';

    char dir[PLATFORM_MAX_PATH], prefix[96], modeSuffix[32], timestampMarker[32];
    BuildPath(Path_SM, dir, sizeof(dir), "%s", RP_DIRECTORY_CHEATERS);
    if (!DirExists(dir)) return false;

    char modeStr[16];
    RV_ModeToString(mode, modeStr, sizeof(modeStr));
    FormatEx(prefix, sizeof(prefix), "%d_%s_", accountID, map);
    char styleShort[16];
    strcopy(styleShort, sizeof(styleShort), gC_StyleNamesShort[Style_Normal]);
    FormatEx(modeSuffix, sizeof(modeSuffix), "_%s_%s.replay", modeStr, styleShort);
    if (eventTime > 0) FormatEx(timestampMarker, sizeof(timestampMarker), "_%d_", eventTime);

    int latestTime = -1;
    DirectoryListing listing = OpenDirectory(dir);
    if (listing == null) return false;

    char entry[PLATFORM_MAX_PATH], fullPath[PLATFORM_MAX_PATH];
    FileType fileType;
    while (listing.GetNext(entry, sizeof(entry), fileType))
    {
        if (fileType != FileType_File || StrContains(entry, prefix, false) != 0) continue;
        if (StrContains(entry, modeSuffix, false) == -1) continue;
        if (eventTime > 0 && StrContains(entry, timestampMarker, false) == -1) continue;

        FormatEx(fullPath, sizeof(fullPath), "%s/%s", dir, entry);
        int modified = GetFileTime(fullPath, FileTime_LastChange);
        if (modified < 0 || modified < eventTime - 1 || GetTime() - modified > RV_REPLAY_MAX_AGE) continue;
        int size = FileSize(fullPath);
        if (size <= 0 || modified <= latestTime) continue;

        latestTime = modified;
        strcopy(output, maxlen, fullPath);
    }
    delete listing;
    return output[0] != '\0';
}

public Action Timer_ScanCheater(Handle timer, DataPack dp)
{
    dp.Reset();
    int userId = dp.ReadCell();
    int accountID = dp.ReadCell();
    char steamid64[32], map[64];
    dp.ReadString(steamid64, sizeof(steamid64));
    dp.ReadString(map, sizeof(map));
    int mode = dp.ReadCell();
    int reason = dp.ReadCell();
    int eventTime = dp.ReadCell();
    int attempt = dp.ReadCell();

    if (!RV_CanUpload()) return Plugin_Stop;

    char sourcePath[PLATFORM_MAX_PATH];
    int sourceModified, sourceSize;
    if (!RV_FindCheaterReplay(accountID, map, mode, eventTime, sourcePath, sizeof(sourcePath)))
    {
        if (attempt < RV_REPLAY_SCAN_MAX_ATTEMPTS)
        {
            RV_ScheduleCheaterScan(userId, accountID, steamid64, map, mode, reason,
                eventTime, attempt + 1);
        }
        else if (gCV_Debug != null && gCV_Debug.BoolValue)
        {
            LogMessage("[replay-vault] Cheater replay was not found after retries for %s", map);
        }
        return Plugin_Stop;
    }

    char modeStr[16], reasonStr[64], date[RV_MAX_DATE_LENGTH], uuid[64], key[RV_MAX_KEY_LENGTH];
    RV_ModeToString(mode, modeStr, sizeof(modeStr));
    int reasonValue = reason;
    if (reasonValue >= 0 && reasonValue < view_as<int>(ACREASON_COUNT))
        strcopy(reasonStr, sizeof(reasonStr), gC_ACReasons[reasonValue]);
    else
        FormatEx(reasonStr, sizeof(reasonStr), "reason_%d", reasonValue);

    RV_FormatDate(GetTime(), date, sizeof(date));
    RV_GenerateUUID(uuid, sizeof(uuid));
    RV_BuildCheaterKey(map, steamid64, modeStr, reasonStr, date, uuid, key, sizeof(key));

    char stagingPath[PLATFORM_MAX_PATH];
    if (!RV_StageFile(sourcePath, uuid, stagingPath, sizeof(stagingPath)))
    {
        LogError("[replay-vault] Failed to stage cheater replay %s", sourcePath);
        return Plugin_Stop;
    }

    RV_GetReplaySignature(sourcePath, sourceModified, sourceSize);
    if (!RV_MarkReplayCaptured(sourcePath, sourceModified, sourceSize))
    {
        RV_DeleteStagingFile(stagingPath);
        return Plugin_Stop;
    }

    RV_UploadFile(stagingPath, key, uuid, map, -1, steamid64, modeStr,
        "cheat", date, 0, userId);
    return Plugin_Stop;
}
