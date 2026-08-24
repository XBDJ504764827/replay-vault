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
    RV_EnsureDir(RV_STAGING_DIR);
}

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

// GetTime() -> yyyy.MM.dd.HH.mm.ss (Beijing +8h via +28800; FormatTime is GMT when 2nd arg omitted on Linux)
// We add 8h offset explicitly so yyyy matches Beijing regardless of server TZ.
void RV_FormatDate(int timestamp, char[] buf, int maxlen)
{
    int beijing = timestamp + 8 * 3600;
    FormatTime(buf, maxlen, "%Y.%m.%d.%H.%M.%S", beijing);
}

// Map sanitize: lower, '/' -> '_' , keep a-z0-9_- .
void RV_SanitizeMap(const char[] input, char[] output, int maxlen)
{
    char lower[64];
    RV_ToLower(input, lower, sizeof(lower));
    int out = 0;
    for (int i = 0; lower[i] != '\0' && out < maxlen - 1; i++)
    {
        char c = lower[i];
        if (c == '/') c = '_';
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.')
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

bool RV_EnsureDir(const char[] dir)
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "%s", dir);
    if (DirExists(path)) return true;
    return CreateDirectory(path, 511);
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

// Parse run filename {course}_{MODE}_{STYLE}_{TIMETYPE}.replay -> course/modeShort/timetype (fallback)
stock bool RV_ParseRunFileName(const char[] fileName, int &course, char[] modeShort, int modeShortLen, char[] typeStr, int typeStrLen)
{
    char buf[PLATFORM_MAX_PATH];
    strcopy(buf, sizeof(buf), fileName);
    int dot = StrContains(buf, ".replay");
    if (dot == -1) return false;
    buf[dot] = '\0';
    char parts[4][16];
    int n = ExplodeString(buf, "_", parts, sizeof(parts), sizeof(parts[]));
    if (n < 4) return false;
    course = StringToInt(parts[0]);
    strcopy(modeShort, modeShortLen, parts[1]);
    RV_ToLower(modeShort, modeShort, modeShortLen);
    if (StrEqual(parts[3], "PRO", false)) strcopy(typeStr, typeStrLen, "pro");
    else strcopy(typeStr, typeStrLen, "nub");
    return true;
}

bool RV_GetSteamID64(int client, char[] buf, int maxlen)
{
    if (GetClientAuthId(client, AuthId_SteamID64, buf, maxlen) && buf[0] != '\0')
    {
        return true;
    }
    int acc = GetSteamAccountID(client);
    if (acc == 0) return false;
    // Fallback: base 76561197960265728 + accountID via string addition (cells are 32-bit, cannot hold 64-bit)
    char base[] = "76561197960265728";
    char accStr[16];
    IntToString(acc, accStr, sizeof(accStr));
    // Add base + accStr as decimal strings
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
    // reverse
    for (int k = 0; k < pos; k++)
    {
        buf[k] = rev[pos - 1 - k];
    }
    buf[pos] = '\0';
    return buf[0] != '\0';
}

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

bool RV_StageFile(const char[] source, const char[] uuid, char[] stagingPath, int maxlen)
{
    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), RV_STAGING_DIR);
    if (!DirExists(dir)) CreateDirectory(dir, 511);
    FormatEx(stagingPath, maxlen, "%s/%s.replay", dir, uuid);
    if (FileExists(stagingPath))
    {
        FormatEx(stagingPath, maxlen, "%s/%s_%d.replay", dir, uuid, ++gI_StageCounter);
    }
    return RV_FileCopy(source, stagingPath);
}
