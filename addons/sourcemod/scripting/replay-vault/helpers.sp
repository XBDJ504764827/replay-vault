// helpers.sp - key building, date, file copy, sanitizers

#define RV_MAX_KEY_LENGTH 512
#define RV_MAX_DATE_LENGTH 32
#define RV_STAGING_DIR "data/replay-vault/staging"

int gI_StageCounter; // staging filename dedup

void RV_OnMapStart_Helpers()
{
    char map[64];
    GetCurrentMapDisplayName(map, sizeof(map));
    RV_ToLower(map, gC_CurrentMap, sizeof(gC_CurrentMap));
    // Ensure staging dir
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), RV_STAGING_DIR);
    if (!DirExists(path)) CreateDirectory(path, 511);
}

// Lowercase in-place
void RV_ToLower(const char[] input, char[] output, int maxlen)
{
    int len = strlen(input);
    if (len >= maxlen) len = maxlen - 1;
    for (int i = 0; i < len; i++)
    {
        char c = input[i];
        if (c >= 'A' && c <= 'Z') c += 32;
        output[i] = c;
    }
    output[len] = '\0';
}

// course 0 -> main, 1 -> b1 ...
void RV_CourseToString(int course, char[] buf, int maxlen)
{
    if (course == 0) strcopy(buf, maxlen, "main");
    else FormatEx(buf, maxlen, "b%d", course);
}

// Mode id -> kzt/skz/vnl lower
void RV_ModeToString(int mode, char[] buf, int maxlen)
{
    char tmp[16];
    strcopy(tmp, sizeof(tmp), gC_ModeNamesShort[mode]);
    RV_ToLower(tmp, buf, maxlen);
}

// TimeType -> pro/nub lower
void RV_TimeTypeToString(int timeType, char[] buf, int maxlen)
{
    char tmp[16];
    strcopy(tmp, sizeof(tmp), gC_TimeTypeNames[timeType]);
    RV_ToLower(tmp, buf, maxlen);
}

// GetTime() -> yyyy.MM.dd.HH.mm.ss (server localtime; doc notes Beijing if server is CST/UTC+8)
void RV_FormatDate(int timestamp, char[] buf, int maxlen)
{
    FormatTime(buf, maxlen, "%Y.%m.%d.%H.%M.%S", timestamp);
}

// Build run key: {map}/runs/{course}/{steamid64}/{mode}/{timetype}/{date}_{uuid}.replay
void RV_BuildRunKey(const char[] map, const char[] courseStr, const char[] steamid64,
    const char[] mode, const char[] timetype, const char[] date, const char[] uuid,
    char[] key, int maxlen)
{
    FormatEx(key, maxlen, "%s/runs/%s/%s/%s/%s/%s_%s.replay",
        map, courseStr, steamid64, mode, timetype, date, uuid);
}

// Build jump key (with optional block)
void RV_BuildJumpKey(const char[] map, const char[] steamid64, const char[] mode,
    const char[] jumpType, int block, const char[] date, const char[] uuid,
    char[] key, int maxlen)
{
    char jumpLower[32];
    RV_ToLower(jumpType, jumpLower, sizeof(jumpLower));
    if (block > 0)
        FormatEx(key, maxlen, "%s/jumps/%s/%s/%s/block_%d/%s_%s.replay",
            map, steamid64, mode, jumpLower, block, date, uuid);
    else
        FormatEx(key, maxlen, "%s/jumps/%s/%s/%s/%s_%s.replay",
            map, steamid64, mode, jumpLower, date, uuid);
}

// Build cheater key
void RV_BuildCheaterKey(const char[] map, const char[] steamid64, const char[] mode,
    const char[] reason, const char[] date, const char[] uuid,
    char[] key, int maxlen)
{
    char reasonLower[64];
    RV_ToLower(reason, reasonLower, sizeof(reasonLower));
    FormatEx(key, maxlen, "%s/cheaters/%s/%s/%s/%s_%s.replay",
        map, steamid64, mode, reasonLower, date, uuid);
}

bool RV_GetSteamID64(int client, char[] buf, int maxlen)
{
    if (GetClientAuthId(client, AuthId_SteamID64, buf, maxlen)) return buf[0] != '\0';
    int acc = GetSteamAccountID(client);
    if (acc == 0) return false;
    // Fallback: compose via accountID (rare, GetClientAuthId should succeed after auth)
    FormatEx(buf, maxlen, "%d", acc);
    return false;
}

// Resolve source path: handle Path_SM-relative vs game-dir-relative (addons/...)
static bool RV_ResolveSourcePath(const char[] source, char[] output, int maxlength)
{
    if (source[0] == '/' || (source[1] == ':' && ((source[0] >= 'A' && source[0] <= 'Z') || (source[0] >= 'a' && source[0] <= 'z'))))
    {
        strcopy(output, maxlength, source);
        return true;
    }
    if (StrContains(source, "addons/") == 0)
    {
        char gameDir[PLATFORM_MAX_PATH];
        BuildPath(Path_SM, gameDir, sizeof(gameDir), "");
        int slashPos = StrContains(gameDir, "/addons/sourcemod");
        if (slashPos == -1) slashPos = StrContains(gameDir, "\\addons\\sourcemod");
        if (slashPos != -1)
        {
            gameDir[slashPos] = '\0';
            Format(output, maxlength, "%s/%s", gameDir, source);
        }
        else strcopy(output, maxlength, source);
        return true;
    }
    BuildPath(Path_SM, output, maxlength, "%s", source);
    return true;
}

bool RV_FileCopy(const char[] source, const char[] destination)
{
    char resolved[PLATFORM_MAX_PATH];
    RV_ResolveSourcePath(source, resolved, sizeof(resolved));
    File src = OpenFile(resolved, "rb");
    if (src == null)
    {
        LogError("[replay-vault] FileCopy cannot open source: %s", resolved);
        return false;
    }
    File dst = OpenFile(destination, "wb");
    if (dst == null)
    {
        LogError("[replay-vault] FileCopy cannot open dest: %s", destination);
        delete src;
        return false;
    }
    int buffer[2048];
    int count;
    while (!src.EndOfFile())
    {
        count = src.Read(buffer, 2048, 1);
        if (count <= 0) break;
        dst.Write(buffer, count, 1);
    }
    delete src;
    delete dst;
    return true;
}

// Build staging path: data/replay-vault/staging/{uuid}.replay (with counter dedup)
bool RV_StageFile(const char[] source, const char[] uuid, char[] stagingPath, int maxlen)
{
    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), RV_STAGING_DIR);
    if (!DirExists(dir)) CreateDirectory(dir, 511);
    // Use uuid directly; counter only if collision (should not happen)
    FormatEx(stagingPath, maxlen, "%s/%s.replay", dir, uuid);
    if (FileExists(stagingPath))
    {
        FormatEx(stagingPath, maxlen, "%s/%s_%d.replay", dir, uuid, ++gI_StageCounter);
    }
    return RV_FileCopy(source, stagingPath);
}
