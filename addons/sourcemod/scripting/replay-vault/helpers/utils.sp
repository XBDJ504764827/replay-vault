// helpers/utils.sp - Common utilities for replay-vault
// Extracted from helpers.sp to reduce file size and improve maintainability

#define RV_MAX_KEY_LENGTH 512
#define RV_MAX_DATE_LENGTH 32
#define RV_STAGING_DIR "data/replay-vault/staging"

// Helper functions for string manipulation and path handling
void RV_ToLower(const char[] input, char[] output, int maxlen)
{
    if (maxlen <= 0) return;
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

void RV_SanitizeSegment(const char[] input, char[] output, int maxlen)
{
    if (maxlen <= 0) return;

    int out = 0;
    for (int i = 0; input[i] != '\0' && out < maxlen - 1; i++)
    {
        char c = input[i];
        if (c >= 'A' && c <= 'Z') c += 32;
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
            || c == '_' || c == '-' || c == '.')
        {
            output[out++] = c;
        }
        else
        {
            output[out++] = '_';
        }
    }
    output[out] = '\0';
}

void RV_SanitizeMap(const char[] input, char[] output, int maxlen)
{
    RV_SanitizeSegment(input, output, maxlen);
}

void RV_CourseToString(int course, char[] buf, int maxlen)
{
    if (course == 0) strcopy(buf, maxlen, "main");
    else FormatEx(buf, maxlen, "b%d", course);
}

void RV_ModeToString(int mode, char[] buf, int maxlen)
{
    if (mode < 0 || mode >= MODE_COUNT)
    {
        strcopy(buf, maxlen, "kzt");
        return;
    }
    char tmp[16];
    strcopy(tmp, sizeof(tmp), gC_ModeNamesShort[mode]);
    RV_ToLower(tmp, buf, maxlen);
}

void RV_TimeTypeToString(int timeType, char[] buf, int maxlen)
{
    if (timeType < 0 || timeType >= TIMETYPE_COUNT)
    {
        strcopy(buf, maxlen, "pro");
        return;
    }
    char tmp[16];
    strcopy(tmp, sizeof(tmp), gC_TimeTypeNames[timeType]);
    RV_ToLower(tmp, buf, maxlen);
}

void RV_FormatDate(int timestamp, char[] buf, int maxlen)
{
    int beijing = timestamp + 8 * 3600;
    FormatTime(buf, maxlen, "%Y.%m.%d.%H.%M.%S", beijing);
}

void RV_GetFileName(const char[] path, char[] output, int maxlen)
{
    int lastSlash = -1;
    for (int i = 0; path[i] != '\0'; i++)
    {
        if (path[i] == '/' || path[i] == '\\') lastSlash = i;
    }
    if (lastSlash == -1) strcopy(output, maxlen, path);
    else strcopy(output, maxlen, path[lastSlash + 1]);
}

bool RV_EnsureDir(const char[] dir)
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "%s", dir);
    return RV_EnsureAbsoluteDir(path);
}

bool RV_EnsureAbsoluteDir(const char[] path)
{
    if (DirExists(path)) return true;

    int len = strlen(path);
    int slash = -1;
    for (int i = len - 1; i > 0; i--)
    {
        if (path[i] == '/' || path[i] == '\\')
        {
            slash = i;
            break;
        }
    }

    if (slash > 0)
    {
        char parent[PLATFORM_MAX_PATH];
        strcopy(parent, sizeof(parent), path);
        parent[slash] = '\0';
        if (!RV_EnsureAbsoluteDir(parent)) return false;
    }

    if (DirExists(path)) return true;
    return CreateDirectory(path, 511) || DirExists(path);
}

void RV_BuildRunKey(const char[] map, const char[] courseStr, const char[] steamid64,
    const char[] mode, const char[] timetype, const char[] date, const char[] uuid,
    char[] key, int maxlen)
{
    char safeMap[64], safeCourse[16], safeSteamID[32], safeMode[16], safeTimeType[16];
    RV_SanitizeSegment(map, safeMap, sizeof(safeMap));
    RV_SanitizeSegment(courseStr, safeCourse, sizeof(safeCourse));
    RV_SanitizeSegment(steamid64, safeSteamID, sizeof(safeSteamID));
    RV_SanitizeSegment(mode, safeMode, sizeof(safeMode));
    RV_SanitizeSegment(timetype, safeTimeType, sizeof(safeTimeType));
    FormatEx(key, maxlen, "%s/runs/%s/%s/%s/%s/%s_%s.replay",
        safeMap, safeCourse, safeSteamID, safeMode, safeTimeType, date, uuid);
}

void RV_BuildJumpKey(const char[] map, const char[] steamid64, const char[] mode,
    const char[] jumpType, int block, const char[] date, const char[] uuid,
    char[] key, int maxlen)
{
    char safeMap[64], safeSteamID[32], safeMode[16], jumpLower[32];
    RV_SanitizeSegment(map, safeMap, sizeof(safeMap));
    RV_SanitizeSegment(steamid64, safeSteamID, sizeof(safeSteamID));
    RV_SanitizeSegment(mode, safeMode, sizeof(safeMode));
    RV_SanitizeSegment(jumpType, jumpLower, sizeof(jumpLower));
    if (block > 0)
        FormatEx(key, maxlen, "%s/jumps/%s/%s/%s/block_%d/%s_%s.replay",
            safeMap, safeSteamID, safeMode, jumpLower, block, date, uuid);
    else
        FormatEx(key, maxlen, "%s/jumps/%s/%s/%s/%s_%s.replay",
            safeMap, safeSteamID, safeMode, jumpLower, date, uuid);
}

void RV_BuildCheaterKey(const char[] map, const char[] steamid64, const char[] mode,
    const char[] reason, const char[] date, const char[] uuid,
    char[] key, int maxlen)
{
    char safeMap[64], safeSteamID[32], safeMode[16], reasonLower[64];
    RV_SanitizeSegment(map, safeMap, sizeof(safeMap));
    RV_SanitizeSegment(steamid64, safeSteamID, sizeof(safeSteamID));
    RV_SanitizeSegment(mode, safeMode, sizeof(safeMode));
    RV_SanitizeSegment(reason, reasonLower, sizeof(reasonLower));
    FormatEx(key, maxlen, "%s/cheaters/%s/%s/%s/%s_%s.replay",
        safeMap, safeSteamID, safeMode, reasonLower, date, uuid);
}

bool RV_GetSteamID64(int client, char[] buf, int maxlen)
{
    if (maxlen < 21)
    {
        if (maxlen > 0) buf[0] = '\0';
        return false;
    }
    buf[0] = '\0';
    if (GetClientAuthId(client, AuthId_SteamID64, buf, maxlen) && buf[0] != '\0')
    {
        return true;
    }
    int acc = GetSteamAccountID(client);
    if (acc == 0) return false;
    char base[] = "76561197960265728";
    char accStr[16];
    IntToString(acc, accStr, sizeof(accStr));
    int i = strlen(base) - 1;
    int j = strlen(accStr) - 1;
    int carry = 0;
    char rev[32];
    int pos = 0;
    while (i >= 0 || j >= 0 || carry)
    {
        int da = (i >= 0) ? (base[i] - '0') : 0;
        int db = (j >= 0) ? (accStr[j] - '0') : 0;
        int sum = da + db + carry;
        rev[pos++] = (sum % 10) + '0';
        carry = sum / 10;
        i--; j--;
    }
    for (int k = 0; k < pos; k++)
    {
        buf[k] = rev[pos - 1 - k];
    }
    buf[pos] = '\0';
    return buf[0] != '\0';
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
    bool ok = true;
    while ((count = src.Read(buffer, sizeof(buffer), 1)) > 0)
    {
        if (!dst.Write(buffer, count, 1))
        {
            ok = false;
            break;
        }
    }
    if (count < 0) ok = false;
    delete src;
    delete dst;
    if (!ok && FileExists(destination)) DeleteFile(destination);
    return ok;
}

bool RV_StageFile(const char[] source, const char[] uuid, char[] stagingPath, int maxlen)
{
    stagingPath[0] = '\0';
    if (!RV_EnsureDir(RV_STAGING_DIR)) return false;

    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), RV_STAGING_DIR);
    FormatEx(stagingPath, maxlen, "%s/%s.replay", dir, uuid);
    int suffix = 0;
    while (FileExists(stagingPath) && suffix < 1000)
    {
        FormatEx(stagingPath, maxlen, "%s/%s_%d.replay", dir, uuid, ++gI_StageCounter);
        suffix++;
    }
    if (FileExists(stagingPath))
    {
        stagingPath[0] = '\0';
        return false;
    }
    return RV_FileCopy(source, stagingPath);
}

void RV_ResolveSourcePath(const char[] source, char[] output, int maxlength)
{
    if (source[0] == '/' || (source[1] == ':' && ((source[0] >= 'A' && source[0] <= 'Z') || (source[0] >= 'a' && source[0] <= 'z'))))
    {
        strcopy(output, maxlength, source);
        return;
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
        return;
    }
    BuildPath(Path_SM, output, maxlength, "%s", source);
    return;
}
