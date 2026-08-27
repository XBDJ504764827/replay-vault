// upload.sp - SteamWorks POST to Worker (Worker relay, no R2 signing in Pawn)
// 失败处理：首个失败即时向完成者本人提示一次(#4)；随后保留 staging 文件，
// 由后台扫描器按固定退避表重试，超龄/超次数才删除(#1)。
// 减少无效请求：仅对传输故障 / 5xx / 408 / 429 重试，其余状态码视为永久性错误直接放弃。

#define RV_REPLAY_SUFFIX_LEN 7   // strlen(".replay")
#define RV_META_SUFFIX_LEN 5     // strlen(".meta")
#define RV_ORPHAN_MAX_AGE 3600   // 无 meta 的孤儿 staging 文件最长保留 1 小时
#define RV_INFLIGHT_TIMEOUT 600  // in-flight 标记最长有效期(秒)，超过视为回调丢失
#define RV_SCAN_TICK_SECONDS 15  // 扫描器心跳间隔，实际扫描频率由 retry_interval 控制

// 固定退避表：每次失败后距下次重试的分钟数。
// 总计首传 1 次 + 重试最多 6 次 = 每份录像最多 7 个请求。
static const int RV_RETRY_DELAYS_MIN[] = { 2, 10, 30, 120, 360, 720 };
#define RV_STAGING_MAX_ATTEMPTS (sizeof(RV_RETRY_DELAYS_MIN) + 1)

// staging 伴生元数据（{uuid}.meta），跨图/重启后可恢复重试所需的全部上传头字段
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
	int Attempts;  // 已完成的发送次数（0 = 尚未发送）
	int NextRetry; // 下次允许重试的 Unix 时间（0 = 尽快）
	int Created;   // staging 元数据创建时间
}

StringMap gM_InFlight; // uuid -> 进入 in-flight 的 Unix 时间，防止扫描器与回调并发重复上传
int gI_LastScanTime;

void RV_InitUploadState()
{
	if (gM_InFlight == null)
	{
		gM_InFlight = new StringMap();
	}
}

// 启动常驻扫描器心跳（插件级定时器，不随换图销毁）
void RV_InitStagingScanner()
{
	RV_InitUploadState();
	CreateTimer(float(RV_SCAN_TICK_SECONDS), Timer_ScanTick, _, TIMER_REPEAT);
}

void RV_MarkInFlight(const char[] uuid)
{
	gM_InFlight.SetValue(uuid, GetTime(), true);
}

void RV_ClearInFlight(const char[] uuid)
{
	gM_InFlight.Remove(uuid);
}

bool RV_IsInFlightFresh(const char[] uuid)
{
	int entered;
	if (!gM_InFlight.GetValue(uuid, entered))
	{
		return false;
	}
	return GetTime() - entered <= RV_INFLIGHT_TIMEOUT;
}

void RV_UpdateDependencies()
{
    gB_SteamWorksOK = GetExtensionFileStatus("SteamWorks.ext") > 0;
}

int RV_GetTimeoutSeconds()
{
    int timeout = gCV_Timeout != null ? gCV_Timeout.IntValue : 60;
    if (timeout < 1) return 1;
    if (timeout > 300) return 300;
    return timeout;
}

void RV_DeleteStagingFile(const char[] stagingPath)
{
    if (stagingPath[0] != '\0' && FileExists(stagingPath) && !DeleteFile(stagingPath))
    {
        LogError("[replay-vault] Failed to delete staging file: %s", stagingPath);
    }
}

// 删除 .replay 与其伴生 .meta
void RV_DeleteStagedPair(const char[] stagingPath)
{
    RV_DeleteStagingFile(stagingPath);
    char metaPath[PLATFORM_MAX_PATH];
    RV_MetaPathOf(stagingPath, metaPath, sizeof(metaPath));
    RV_DeleteStagingFile(metaPath);
}

// 从 {uuid}.replay 推导伴生元数据路径 {uuid}.meta
void RV_MetaPathOf(const char[] stagingPath, char[] output, int maxlen)
{
    char tmp[PLATFORM_MAX_PATH];
    strcopy(tmp, sizeof(tmp), stagingPath);
    int len = strlen(tmp);
    if (len > RV_REPLAY_SUFFIX_LEN && strcmp(tmp[len - RV_REPLAY_SUFFIX_LEN], ".replay", false) == 0)
    {
        tmp[len - RV_REPLAY_SUFFIX_LEN] = '\0';
    }
    FormatEx(output, maxlen, "%s.meta", tmp);
}

bool RV_ReadMeta(const char[] metaPath, ReplayStageMeta meta)
{
    File file = OpenFile(metaPath, "rb");
    if (file == null) return false;

    char line[800], field[16], value[640];
    while (file.ReadLine(line, sizeof(line)))
    {
        TrimString(line);
        if (line[0] == '\0' || line[0] == '#') continue;
        int eq = FindCharInString(line, '=');
        if (eq <= 0) continue;
        strcopy(field, eq + 1, line);
        strcopy(value, sizeof(value), line[eq + 1]);
        if (StrEqual(field, "key")) strcopy(meta.Key, sizeof(meta.Key), value);
        else if (StrEqual(field, "map")) strcopy(meta.Map, sizeof(meta.Map), value);
        else if (StrEqual(field, "course")) meta.Course = StringToInt(value);
        else if (StrEqual(field, "steamid64")) strcopy(meta.SteamID64, sizeof(meta.SteamID64), value);
        else if (StrEqual(field, "mode")) strcopy(meta.Mode, sizeof(meta.Mode), value);
        else if (StrEqual(field, "timetype")) strcopy(meta.TimeType, sizeof(meta.TimeType), value);
        else if (StrEqual(field, "date")) strcopy(meta.Date, sizeof(meta.Date), value);
        else if (StrEqual(field, "timeMs")) meta.TimeMs = StringToInt(value);
        else if (StrEqual(field, "userid")) meta.UserId = StringToInt(value);
        else if (StrEqual(field, "attempts")) meta.Attempts = StringToInt(value);
        else if (StrEqual(field, "nextRetry")) meta.NextRetry = StringToInt(value);
        else if (StrEqual(field, "created")) meta.Created = StringToInt(value);
    }
    delete file;
    return meta.Key[0] != '\0' && meta.Map[0] != '\0' && meta.SteamID64[0] != '\0';
}

bool RV_WriteMeta(const char[] metaPath, const ReplayStageMeta meta)
{
    File file = OpenFile(metaPath, "wb");
    if (file == null) return false;
    file.WriteLine("key=%s", meta.Key);
    file.WriteLine("map=%s", meta.Map);
    file.WriteLine("course=%d", meta.Course);
    file.WriteLine("steamid64=%s", meta.SteamID64);
    file.WriteLine("mode=%s", meta.Mode);
    file.WriteLine("timetype=%s", meta.TimeType);
    file.WriteLine("date=%s", meta.Date);
    file.WriteLine("timeMs=%d", meta.TimeMs);
    file.WriteLine("userid=%d", meta.UserId);
    file.WriteLine("attempts=%d", meta.Attempts);
    file.WriteLine("nextRetry=%d", meta.NextRetry);
    file.WriteLine("created=%d", meta.Created);
    delete file;
    return true;
}

bool RV_ShouldAnnounceKey(const char[] key)
{
    bool isRun = StrContains(key, "/runs/") != -1;
    return isRun ? (gCV_Chat != null && gCV_Chat.BoolValue)
                 : (gCV_AnnounceJumps != null && gCV_AnnounceJumps.BoolValue);
}

void RV_UploadFile(const char[] stagingPath, const char[] key, const char[] uuid,
    const char[] map, int course, const char[] steamid64, const char[] mode,
    const char[] timetype, const char[] date, int timeMs, int clientUserId)
{
    if (!RV_CanUpload())
    {
        if (gCV_Debug != null && gCV_Debug.BoolValue)
            LogMessage("[replay-vault] Skip upload (disabled or url/key empty) key=%s uuid=%s", key, uuid);
        RV_DeleteStagingFile(stagingPath);
        return;
    }

    if (!FileExists(stagingPath))
    {
        LogError("[replay-vault] Staging file does not exist: %s", stagingPath);
        return;
    }

    char url[512];
    gCV_Url.GetString(url, sizeof(url));
    TrimString(url);
    int len = strlen(url);
    while (len > 8 && url[len - 1] == '/')
    {
        url[--len] = '\0';
    }
    if (url[0] == '\0')
    {
        RV_DeleteStagingFile(stagingPath);
        return;
    }

    char apiKey[256];
    gCV_Key.GetString(apiKey, sizeof(apiKey));
    TrimString(apiKey);

    Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, url);
    if (hRequest == null)
    {
        LogError("[replay-vault] Failed to create HTTP request key=%s uuid=%s", key, uuid);
        RV_DeleteStagingFile(stagingPath);
        return;
    }

    int timeoutSec = RV_GetTimeoutSeconds();
    SteamWorks_SetHTTPRequestNetworkActivityTimeout(hRequest, timeoutSec);
    SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(hRequest, timeoutSec * 1000);
    bool headersOk = true;
    headersOk = SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-API-Key", apiKey) && headersOk;
    headersOk = SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-UUID", uuid) && headersOk;
    headersOk = SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-Key", key) && headersOk;
    headersOk = SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-Map", map) && headersOk;
    char courseStr[16], timeMsStr[16], timestampStr[16];
    IntToString(course, courseStr, sizeof(courseStr));
    IntToString(timeMs, timeMsStr, sizeof(timeMsStr));
    IntToString(GetTime(), timestampStr, sizeof(timestampStr));
    headersOk = SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-Course", courseStr) && headersOk;
    headersOk = SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-Mode", mode) && headersOk;
    headersOk = SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-TimeType", timetype) && headersOk;
    headersOk = SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-Time-Ms", timeMsStr) && headersOk;
    headersOk = SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-Timestamp", timestampStr) && headersOk;
    headersOk = SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-Date", date) && headersOk;
    headersOk = SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-SteamID64", steamid64) && headersOk;

    char replayType[16];
    if (StrContains(key, "/runs/") != -1) strcopy(replayType, sizeof(replayType), "run");
    else if (StrContains(key, "/jumps/") != -1) strcopy(replayType, sizeof(replayType), "jump");
    else strcopy(replayType, sizeof(replayType), "cheat");
    headersOk = SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-Replay-Type", replayType) && headersOk;

    if (!headersOk)
    {
        LogError("[replay-vault] Failed to set HTTP headers key=%s uuid=%s", key, uuid);
        delete hRequest;
        RV_DeleteStagingFile(stagingPath);
        return;
    }

    if (!SteamWorks_SetHTTPRequestRawPostBodyFromFile(hRequest, "application/octet-stream", stagingPath))
    {
        LogError("[replay-vault] Failed to set POST body from %s key=%s", stagingPath, key);
        delete hRequest;
        RV_DeleteStagingFile(stagingPath);
        return;
    }

    // 发送前写入伴生元数据并登记 in-flight：
    // 成功 → 一并删除；失败 → 保留，交给扫描器按退避计划重试；崩溃残留 → 由扫描器兜底恢复
    RV_InitUploadState();

    ReplayStageMeta meta;
    strcopy(meta.Key, sizeof(meta.Key), key);
    strcopy(meta.Map, sizeof(meta.Map), map);
    meta.Course = course;
    strcopy(meta.SteamID64, sizeof(meta.SteamID64), steamid64);
    strcopy(meta.Mode, sizeof(meta.Mode), mode);
    strcopy(meta.TimeType, sizeof(meta.TimeType), timetype);
    strcopy(meta.Date, sizeof(meta.Date), date);
    meta.TimeMs = timeMs;
    meta.UserId = clientUserId;
    meta.Attempts = 0;
    meta.NextRetry = 0;
    meta.Created = GetTime();

    char metaPath[PLATFORM_MAX_PATH];
    RV_MetaPathOf(stagingPath, metaPath, sizeof(metaPath));
    if (!RV_WriteMeta(metaPath, meta))
    {
        LogError("[replay-vault] Failed to write staging meta, upload proceeds without crash recovery: %s", metaPath);
    }

    RV_MarkInFlight(uuid);

    DataPack pack = new DataPack();
    pack.WriteString(uuid);
    pack.WriteString(key);
    pack.WriteString(stagingPath);
    pack.WriteCell(clientUserId);
    pack.WriteString(map);
    pack.WriteString(mode);
    pack.WriteString(timetype);
    pack.WriteString(date);
    pack.WriteString(steamid64);
    pack.WriteCell(course);
    pack.WriteCell(timeMs);

    if (!SteamWorks_SetHTTPRequestContextValue(hRequest, pack)
        || !SteamWorks_SetHTTPCallbacks(hRequest, RV_OnUploadCompleted))
    {
        LogError("[replay-vault] Failed to configure HTTP request key=%s uuid=%s", key, uuid);
        delete pack;
        delete hRequest;
        RV_ClearInFlight(uuid);
        RV_DeleteStagedPair(stagingPath);
        return;
    }

    if (gCV_Debug != null && gCV_Debug.BoolValue)
        LogMessage("[replay-vault] Uploading %s uuid=%s key=%s timeout=%ds", stagingPath, uuid, key, timeoutSec);

    if (!SteamWorks_SendHTTPRequest(hRequest))
    {
        LogError("[replay-vault] Failed to send HTTP request key=%s uuid=%s", key, uuid);
        delete pack;
        delete hRequest;
        RV_ClearInFlight(uuid);
        RV_DeleteStagedPair(stagingPath);
    }
}

public void RV_OnUploadCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data)
{
    DataPack pack = view_as<DataPack>(data);
    if (pack == null)
    {
        delete hRequest;
        return;
    }
    pack.Reset();
    char uuid[64], key[512], stagingPath[PLATFORM_MAX_PATH];
    pack.ReadString(uuid, sizeof(uuid));
    pack.ReadString(key, sizeof(key));
    pack.ReadString(stagingPath, sizeof(stagingPath));
    int clientUserId = pack.ReadCell();
    char map[64], mode[16], timetype[16], date[32], steamid64[32];
    pack.ReadString(map, sizeof(map));
    pack.ReadString(mode, sizeof(mode));
    pack.ReadString(timetype, sizeof(timetype));
    pack.ReadString(date, sizeof(date));
    pack.ReadString(steamid64, sizeof(steamid64));
    pack.ReadCell();
    int timeMs = pack.ReadCell();
    delete pack;

    RV_InitUploadState();
    RV_ClearInFlight(uuid);

    int code = view_as<int>(eStatusCode);
    bool is2xx = !bFailure && bRequestSuccessful && code >= 200 && code < 300;

    if (is2xx)
    {
        RV_DeleteStagedPair(stagingPath);
        if (RV_ShouldAnnounceKey(key))
        {
            int client = GetClientOfUserId(clientUserId);
            if (client > 0 && IsClientInGame(client) && !IsFakeClient(client))
            {
                if (GetFeatureStatus(FeatureType_Native, "GOKZ_PrintToChat") == FeatureStatus_Available)
                    GOKZ_PrintToChat(client, true, "%t{%s}", "Replay Uploaded Prefix", uuid);
                else
                {
                    // 普通 PrintToChat 不解析 {} 颜色标签，回退为纯文本前缀 + UUID
                    char prefix[96];
                    FormatEx(prefix, sizeof(prefix), "%T", "Replay Uploaded Prefix", client);
                    PrintToChat(client, "[replay-vault] %s%s", prefix, uuid);
                }
            }
        }
        if (gCV_Debug != null && gCV_Debug.BoolValue)
            LogMessage("[replay-vault] Upload OK key=%s uuid=%s status=%d timeMs=%d", key, uuid, code, timeMs);
        else
            LogMessage("[replay-vault] Uploaded uuid=%s key=%s", uuid, key);
    }
    else
    {
        LogError("[replay-vault] Upload failed key=%s uuid=%s failure=%d success=%d status=%d",
            key, uuid, bFailure ? 1 : 0, bRequestSuccessful ? 1 : 0, code);
        if (code == 401)
            LogError("[replay-vault]   -> 401: replay_vault_key mismatch with Worker API_KEY");
        else if (code == 400)
            LogError("[replay-vault]   -> 400: missing/invalid headers (X-UUID/X-Key/X-Map etc.)");
        RV_HandleUploadFailure(stagingPath, key, uuid, code, bFailure || !bRequestSuccessful);
    }
    delete hRequest;
}

// 上传失败统一出口：决定「保留重试」还是「立即放弃」，首个失败只通知玩家一次
void RV_HandleUploadFailure(const char[] stagingPath, const char[] key, const char[] uuid,
    int code, bool transportError)
{
    char metaPath[PLATFORM_MAX_PATH];
    RV_MetaPathOf(stagingPath, metaPath, sizeof(metaPath));

    ReplayStageMeta meta;
    if (!RV_ReadMeta(metaPath, meta))
    {
        LogError("[replay-vault] Staged metadata unreadable, dropping replay uuid=%s key=%s status=%d",
            uuid, key, code);
        RV_DeleteStagedPair(stagingPath);
        return;
    }

    bool firstFailure = (meta.Attempts == 0);
    // 减少无效请求：仅传输故障 / 5xx / 408 / 429 可重试，其余按永久性错误立即放弃
    bool retryable = transportError
        || (code >= 500 && code <= 599)
        || code == 408
        || code == 429;
    int attempts = meta.Attempts + 1;

    if (retryable && attempts < RV_STAGING_MAX_ATTEMPTS)
    {
        meta.Attempts = attempts;
        meta.NextRetry = GetTime() + RV_RETRY_DELAYS_MIN[attempts - 1] * 60;
        if (!RV_WriteMeta(metaPath, meta))
        {
            // 写失败则保留旧 meta，扫描器仍会按原计划兜底
            LogError("[replay-vault] Failed to update staging meta uuid=%s (keeping old schedule)", uuid);
        }
        if (gCV_Debug != null && gCV_Debug.BoolValue)
            LogMessage("[replay-vault] Retry #%d scheduled for uuid=%s in %d minute(s)",
                attempts, uuid, RV_RETRY_DELAYS_MIN[attempts - 1]);

        if (firstFailure)
        {
            RV_NotifyFirstFailure(meta.UserId, key, code);
        }
        return;
    }

    LogError("[replay-vault] Dropping staged replay uuid=%s key=%s attempts=%d status=%d (%s)",
        uuid, key, attempts, code,
        !retryable ? "non-retryable status" : "retry budget exhausted");
    RV_DeleteStagedPair(stagingPath);

    if (firstFailure)
    {
        RV_NotifyFirstFailure(meta.UserId, key, code);
    }
}

// 仅在第一次失败时调用：向完成者本人提示一次，后续重试失败不再打扰
void RV_NotifyFirstFailure(int userId, const char[] key, int code)
{
    if (!RV_ShouldAnnounceKey(key)) return;
    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client)) return;

    if (GetFeatureStatus(FeatureType_Native, "GOKZ_PrintToChat") == FeatureStatus_Available)
        GOKZ_PrintToChat(client, true, "%t", "Replay Upload Failed");
    else
    {
        char msg[128];
        FormatEx(msg, sizeof(msg), "%T", "Replay Upload Failed", client);
        PrintToChat(client, "[replay-vault] %s", msg);
    }
    LogMessage("[replay-vault] Notified userId=%d of first upload failure (status=%d)", userId, code);
}

public Action Timer_ScanTick(Handle timer)
{
    RV_InitUploadState();
    if (!RV_CanUpload()) return Plugin_Continue;

    int now = GetTime();
    int interval = gCV_RetryInterval != null ? gCV_RetryInterval.IntValue : 60;
    if (gI_LastScanTime != 0 && now - gI_LastScanTime < interval) return Plugin_Continue;
    gI_LastScanTime = now;
    RV_ScanStaging(now);
    return Plugin_Continue;
}

// 后台扫描器：重试到期条目、清理孤儿 staging 文件、淘汰超龄/超次的失败件
void RV_ScanStaging(int now)
{
    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), RV_STAGING_DIR);
    DirectoryListing listing = OpenDirectory(dir);
    if (listing == null) return;

    ArrayList replays = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    ArrayList metas = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    char entry[PLATFORM_MAX_PATH];
    FileType fileType;
    while (listing.GetNext(entry, sizeof(entry), fileType))
    {
        if (fileType != FileType_File) continue;
        int len = strlen(entry);
        if (len > RV_REPLAY_SUFFIX_LEN && strcmp(entry[len - RV_REPLAY_SUFFIX_LEN], ".replay", false) == 0)
            replays.PushString(entry);
        else if (len > RV_META_SUFFIX_LEN && strcmp(entry[len - RV_META_SUFFIX_LEN], ".meta", false) == 0)
            metas.PushString(entry);
    }
    delete listing;

    int retried = 0, dropped = 0, cleaned = 0;
    char fullPath[PLATFORM_MAX_PATH], metaPath[PLATFORM_MAX_PATH];

    for (int i = 0; i < replays.Length; i++)
    {
        replays.GetString(i, entry, sizeof(entry));
        FormatEx(fullPath, sizeof(fullPath), "%s/%s", dir, entry);
        if (!FileExists(fullPath)) continue;

        int uuidLen = strlen(entry) - RV_REPLAY_SUFFIX_LEN;
        entry[uuidLen] = '\0'; // entry 现在就是 uuid
        FormatEx(metaPath, sizeof(metaPath), "%s/%s.meta", dir, entry);

        if (RV_IsInFlightFresh(entry)) continue;
        if (gM_InFlight.ContainsKey(entry))
        {
            // 回调疑似丢失（超过 in-flight 时限），解除占用
            gM_InFlight.Remove(entry);
        }

        ReplayStageMeta meta;
        if (!RV_ReadMeta(metaPath, meta))
        {
            // 孤儿 .replay：崩溃于写 meta 之前的历史残留，超时清理
            int modified = GetFileTime(fullPath, FileTime_LastChange);
            if (modified >= 0 && now - modified > RV_ORPHAN_MAX_AGE)
            {
                RV_DeleteStagingFile(fullPath);
                cleaned++;
            }
            continue;
        }

        int maxAgeSec = (gCV_StagingMaxAge != null ? gCV_StagingMaxAge.IntValue : 24) * 3600;
        if (now - meta.Created > maxAgeSec || meta.Attempts >= RV_STAGING_MAX_ATTEMPTS)
        {
            LogError("[replay-vault] Dropping staged replay uuid=%s key=%s attempts=%d age=%ds (gave up)",
                entry, meta.Key, meta.Attempts, now - meta.Created);
            RV_DeleteStagingFile(fullPath);
            RV_DeleteStagingFile(metaPath);
            dropped++;
            continue;
        }

        if (meta.NextRetry > now) continue;

        retried++;
        if (gCV_Debug != null && gCV_Debug.BoolValue)
            LogMessage("[replay-vault] Retrying staged upload uuid=%s attempts=%d", entry, meta.Attempts);
        RV_UploadFile(fullPath, meta.Key, entry, meta.Map, meta.Course, meta.SteamID64,
            meta.Mode, meta.TimeType, meta.Date, meta.TimeMs, meta.UserId);
    }

    // 清理没有对应 .replay 的孤儿 .meta（成功路径删除中断的残留）
    for (int i = 0; i < metas.Length; i++)
    {
        metas.GetString(i, entry, sizeof(entry));
        FormatEx(metaPath, sizeof(metaPath), "%s/%s", dir, entry);
        if (!FileExists(metaPath)) continue;

        int uuidLen = strlen(entry) - RV_META_SUFFIX_LEN;
        entry[uuidLen] = '\0';
        FormatEx(fullPath, sizeof(fullPath), "%s/%s.replay", dir, entry);
        if (FileExists(fullPath)) continue; // 有正主，已在上方处理

        int modified = GetFileTime(metaPath, FileTime_LastChange);
        if (modified >= 0 && now - modified > RV_ORPHAN_MAX_AGE)
        {
            RV_DeleteStagingFile(metaPath);
            cleaned++;
        }
    }

    delete replays;
    delete metas;

    if (dropped > 0 || cleaned > 0)
    {
        LogMessage("[replay-vault] Staging scan: retried=%d dropped=%d cleaned=%d", retried, dropped, cleaned);
    }
    else if (retried > 0 && gCV_Debug != null && gCV_Debug.BoolValue)
    {
        LogMessage("[replay-vault] Staging scan: retried=%d dropped=%d cleaned=%d", retried, dropped, cleaned);
    }
}
