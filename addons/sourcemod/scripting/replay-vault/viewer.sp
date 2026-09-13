// viewer.sp - in-game replay viewer (!rv <uuid>, !rv menu)
//
// UUID -> 本地 cache 命中就直接播；没命中先 GET /replay/{uuid}?meta=1 预检
// （地图 / tickrate / 类型），再 GET /replay/{uuid} 异步下载进 cache，最后调用
// gokz-replays 的 GOKZ_RP_LoadJumpReplay（其实现是通用 LoadReplayBot，Run/Jump
// 均可播）让玩家以观察者视角回看。
//
// 权限：任何持有 UUID 的人都能播；cheater 类录像仅管理员可播。

#define RV_VIEW_MAX_ACTIVE_TASKS 8
#define RV_VIEW_MAX_DOWNLOAD_BYTES (32 * 1024 * 1024)
#define RV_VIEW_MAX_META_BYTES 16384
#define RV_VIEW_ADMIN_OVERRIDE "replay_vault_admin"

static StringMap gM_ViewInFlight;      // uuid -> 1，避免同一 UUID 并发重复处理
static int gI_ViewCooldown[MAXPLAYERS + 1];
static int gI_ActiveViewTasks;

void RV_InitViewer()
{
    RV_InitViewerState();
    for (int i = 0; i <= MaxClients; i++) gI_ViewCooldown[i] = 0;
    gI_ActiveViewTasks = 0;

    RegConsoleCmd("sm_rv", Command_ReplayVault,
        "[KZ] View a replay by UUID (!rv <uuid>) or list your recent replays.");
    RegConsoleCmd("sm_vault", Command_ReplayVault,
        "[KZ] View a replay by UUID (!rv <uuid>) or list your recent replays.");
    RegConsoleCmd("sm_replayvault", Command_ReplayVault,
        "[KZ] View a replay by UUID (!rv <uuid>) or list your recent replays.");
}

void RV_InitViewerState()
{
    if (gM_ViewInFlight == null) gM_ViewInFlight = new StringMap();
}

void RV_OnPluginEnd_Viewer()
{
    delete gM_ViewInFlight;
}

static bool RV_ViewerBaseUrl(char[] output, int maxlen)
{
    if (gCV_Url == null) return false;
    gCV_Url.GetString(output, maxlen);
    TrimString(output);
    int len = strlen(output);
    while (len > 8 && output[len - 1] == '/') output[--len] = '\0';
    return output[0] != '\0';
}

static void RV_ViewerApiKey(char[] output, int maxlen)
{
    output[0] = '\0';
    if (gCV_Key == null) return;
    gCV_Key.GetString(output, maxlen);
    TrimString(output);
}

// 统一聊天出口：优先 GOKZ 带前缀彩色输出，gokz-core 缺席时回退纯文本。
void RV_ViewReply(int client, const char[] phrase, any...)
{
    if (client <= 0 || !IsClientInGame(client) || phrase[0] == '\0') return;

    char buffer[256];
    SetGlobalTransTarget(client);
    VFormat(buffer, sizeof(buffer), "%t", 2);

    if (GetFeatureStatus(FeatureType_Native, "GOKZ_PrintToChat") == FeatureStatus_Available)
    {
        GOKZ_PrintToChat(client, true, "%s", buffer);
    }
    else
    {
        PrintToChat(client, "[replay-vault] %s", buffer);
    }
}

static bool RV_ViewerIsAdmin(int client)
{
    return CheckCommandAccess(client, RV_VIEW_ADMIN_OVERRIDE, ADMFLAG_GENERIC);
}

static int RV_ServerTickrate()
{
    float interval = GetTickInterval();
    return interval > 0.0 ? RoundToZero(1.0 / interval) : 0;
}

void RV_FinishViewTask(const char[] uuid)
{
    RV_InitViewerState();
    if (gM_ViewInFlight.Remove(uuid) && gI_ActiveViewTasks > 0)
    {
        gI_ActiveViewTasks--;
    }
}

// =====[ COMMAND ]=====

public Action Command_ReplayVault(int client, int args)
{
    if (client == 0 || !IsClientInGame(client)) return Plugin_Handled;
    if (!RV_CanView())
    {
        RV_ViewReply(client, "Replay View Disabled");
        return Plugin_Handled;
    }
    if (args < 1)
    {
        RV_OpenReplayMenu(client);
        return Plugin_Handled;
    }

    char raw[64];
    GetCmdArg(1, raw, sizeof(raw));
    RV_RequestView(client, raw);
    return Plugin_Handled;
}

// =====[ VIEW REQUEST ]=====

void RV_RequestView(int client, const char[] rawUuid)
{
    if (GetFeatureStatus(FeatureType_Native, "GOKZ_RP_LoadJumpReplay") != FeatureStatus_Available)
    {
        RV_ViewReply(client, "Replay View Unavailable");
        return;
    }

    char uuid[64];
    if (!RV_NormalizeUUID(rawUuid, uuid, sizeof(uuid)))
    {
        RV_ViewReply(client, "Replay View Invalid UUID");
        return;
    }

    bool isAdmin = RV_ViewerIsAdmin(client);
    int cooldown = gCV_DownloadCooldown != null ? gCV_DownloadCooldown.IntValue : 5;
    int now = GetTime();
    if (!isAdmin && cooldown > 0 && gI_ViewCooldown[client] > 0
        && now - gI_ViewCooldown[client] < cooldown)
    {
        RV_ViewReply(client, "Replay View Cooldown", cooldown - (now - gI_ViewCooldown[client]));
        return;
    }
    gI_ViewCooldown[client] = now;

    char cachePath[PLATFORM_MAX_PATH];
    if (RV_CacheReplayExists(uuid, cachePath, sizeof(cachePath)))
    {
        RV_PlayLocal(client, uuid, cachePath);
        return;
    }

    RV_InitViewerState();
    if (gM_ViewInFlight.ContainsKey(uuid))
    {
        RV_ViewReply(client, "Replay View Downloading");
        return;
    }
    if (gI_ActiveViewTasks >= RV_VIEW_MAX_ACTIVE_TASKS)
    {
        RV_ViewReply(client, "Replay View Busy");
        return;
    }

    RV_FetchReplayMeta(client, uuid);
}

// =====[ PLAYBACK ]=====

void RV_PlayLocal(int client, const char[] uuid, const char[] path)
{
    int replayType = ReplayType_Run, tickrate = 0;
    char mapName[64];
    bool parsed = RV_ParseReplayHeader(path, replayType, tickrate, mapName, sizeof(mapName));

    if (parsed)
    {
        if (replayType == ReplayType_Cheater && !RV_ViewerIsAdmin(client))
        {
            RV_ViewReply(client, "Replay View Admin Only");
            return;
        }
        if (!StrEqual(mapName, gC_CurrentMap, false))
        {
            RV_ViewReply(client, "Replay View Wrong Map", mapName);
            return;
        }
        int serverTickrate = RV_ServerTickrate();
        if (tickrate > 0 && serverTickrate > 0 && tickrate != serverTickrate)
        {
            RV_ViewReply(client, "Replay View Tickrate", tickrate, serverTickrate);
            return;
        }
    }

    char pathBuf[PLATFORM_MAX_PATH];
    strcopy(pathBuf, sizeof(pathBuf), path);

    if (GetFeatureStatus(FeatureType_Native, "GOKZ_RP_LoadJumpReplay") != FeatureStatus_Available)
    {
        RV_ViewReply(client, "Replay View Unavailable");
        return;
    }

    int bot = GOKZ_RP_LoadJumpReplay(client, pathBuf);
    if (bot <= 0)
    {
        if (!parsed)
        {
            // 头都解析不出来：基本可以判定缓存文件损坏，清掉让下次重新下载。
            RV_DeleteCachePair(uuid);
            RV_ViewReply(client, "Replay View Corrupt");
        }
        else
        {
            RV_ViewReply(client, "Replay View Failed");
        }
        return;
    }

    RV_ViewReply(client, "Replay View Playing");
}

// =====[ META (pre-check before download) ]=====

void RV_FetchReplayMeta(int client, const char[] uuid)
{
    char base[512], url[640];
    if (!RV_ViewerBaseUrl(base, sizeof(base)))
    {
        RV_ViewReply(client, "Replay View Disabled");
        return;
    }
    FormatEx(url, sizeof(url), "%s/replay/%s?meta=1", base, uuid);

    Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
    if (hRequest == null)
    {
        RV_ViewReply(client, "Replay View Failed");
        return;
    }

    int timeoutSec = RV_GetTimeoutSeconds();
    SteamWorks_SetHTTPRequestNetworkActivityTimeout(hRequest, timeoutSec);
    SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(hRequest, timeoutSec * 1000);
    char apiKey[256];
    RV_ViewerApiKey(apiKey, sizeof(apiKey));
    if (apiKey[0] != '\0')
    {
        SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-API-Key", apiKey);
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(uuid);

    RV_InitViewerState();
    gM_ViewInFlight.SetValue(uuid, 1, true);
    gI_ActiveViewTasks++;

    if (!SteamWorks_SetHTTPRequestContextValue(hRequest, pack)
        || !SteamWorks_SetHTTPCallbacks(hRequest, RV_OnMetaCompleted))
    {
        delete pack;
        delete hRequest;
        RV_FinishViewTask(uuid);
        RV_ViewReply(client, "Replay View Failed");
        return;
    }

    if (!SteamWorks_SendHTTPRequest(hRequest))
    {
        delete pack;
        delete hRequest;
        RV_FinishViewTask(uuid);
        RV_ViewReply(client, "Replay View Failed");
    }
}

public void RV_OnMetaCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful,
    EHTTPStatusCode eStatusCode, any data)
{
    DataPack pack = view_as<DataPack>(data);
    int clientUserId = pack.ReadCell();
    char uuid[64];
    pack.ReadString(uuid, sizeof(uuid));
    delete pack;

    int client = GetClientOfUserId(clientUserId);
    int code = view_as<int>(eStatusCode);
    bool ok = !bFailure && bRequestSuccessful && code >= 200 && code < 300;

    if (!ok)
    {
        RV_FinishViewTask(uuid);
        if (client > 0 && IsClientInGame(client))
        {
            if (code == 404) RV_ViewReply(client, "Replay View Not Found");
            else RV_ViewReply(client, "Replay View Failed");
        }
        delete hRequest;
        return;
    }

    int size = 0;
    SteamWorks_GetHTTPResponseBodySize(hRequest, size);
    if (size <= 0 || size > RV_VIEW_MAX_META_BYTES)
    {
        RV_FinishViewTask(uuid);
        RV_ViewReply(client, "Replay View Failed");
        delete hRequest;
        return;
    }

    char[] body = new char[size + 1];
    SteamWorks_GetHTTPResponseBodyData(hRequest, body, size + 1);
    body[size] = '\0';
    delete hRequest;

    char key[RV_MAX_KEY_LENGTH], map[64], category[16], steamid64[32];
    char mode[16], timetype[16], date[RV_MAX_DATE_LENGTH];
    key[0] = map[0] = category[0] = steamid64[0] = mode[0] = timetype[0] = date[0] = '\0';
    int course = -1, timeMs = 0, tickrate = 0;
    bool exists = false;

    JSON_Object root = json_decode(body);
    if (root != null)
    {
        exists = root.GetBool("exists", false);
        if (exists)
        {
            root.GetString("key", key, sizeof(key));
            root.GetString("map", map, sizeof(map));
            root.GetString("category", category, sizeof(category));
            root.GetString("steamid64", steamid64, sizeof(steamid64));
            root.GetString("mode", mode, sizeof(mode));
            root.GetString("timetype", timetype, sizeof(timetype));
            root.GetString("date", date, sizeof(date));
            course = root.GetInt("course", -1);
            timeMs = root.GetInt("time_ms", 0);
            tickrate = root.GetInt("tickrate", 0);
        }
        root.Cleanup();
    }

    if (!exists || key[0] == '\0')
    {
        RV_FinishViewTask(uuid);
        RV_ViewReply(client, "Replay View Not Found");
        return;
    }

    if (StrEqual(category, "cheat") && !RV_ViewerIsAdmin(client))
    {
        RV_FinishViewTask(uuid);
        RV_ViewReply(client, "Replay View Admin Only");
        return;
    }
    if (!StrEqual(map, gC_CurrentMap, false))
    {
        RV_FinishViewTask(uuid);
        RV_ViewReply(client, "Replay View Wrong Map", map);
        return;
    }
    int serverTickrate = RV_ServerTickrate();
    if (tickrate > 0 && serverTickrate > 0 && tickrate != serverTickrate)
    {
        RV_FinishViewTask(uuid);
        RV_ViewReply(client, "Replay View Tickrate", tickrate, serverTickrate);
        return;
    }

    if (!IsClientInGame(client))
    {
        // 玩家已离开：没必要下载，交给下次请求。
        RV_FinishViewTask(uuid);
        return;
    }

    RV_StartDownload(client, uuid, key, map, course, steamid64, mode, timetype, date,
        timeMs, category, tickrate);
}

// =====[ DOWNLOAD ]=====

void RV_StartDownload(int client, const char[] uuid, const char[] key, const char[] map,
    int course, const char[] steamid64, const char[] mode, const char[] timetype,
    const char[] date, int timeMs, const char[] category, int tickrate)
{
    if (!RV_EnsureCacheDir())
    {
        RV_FinishViewTask(uuid);
        RV_ViewReply(client, "Replay View Failed");
        return;
    }

    char base[512], url[640];
    if (!RV_ViewerBaseUrl(base, sizeof(base)))
    {
        RV_FinishViewTask(uuid);
        RV_ViewReply(client, "Replay View Disabled");
        return;
    }
    FormatEx(url, sizeof(url), "%s/replay/%s", base, uuid);

    Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
    if (hRequest == null)
    {
        RV_FinishViewTask(uuid);
        RV_ViewReply(client, "Replay View Failed");
        return;
    }

    int timeoutSec = RV_GetTimeoutSeconds();
    SteamWorks_SetHTTPRequestNetworkActivityTimeout(hRequest, timeoutSec);
    SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(hRequest, timeoutSec * 1000);
    char apiKey[256];
    RV_ViewerApiKey(apiKey, sizeof(apiKey));
    if (apiKey[0] != '\0')
    {
        SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-API-Key", apiKey);
    }

    char partPath[PLATFORM_MAX_PATH];
    RV_CachePartPathOf(uuid, partPath, sizeof(partPath));
    if (FileExists(partPath)) DeleteFile(partPath);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(uuid);
    pack.WriteString(key);
    pack.WriteString(map);
    pack.WriteCell(course);
    pack.WriteString(steamid64);
    pack.WriteString(mode);
    pack.WriteString(timetype);
    pack.WriteString(date);
    pack.WriteCell(timeMs);
    pack.WriteString(category);
    pack.WriteCell(tickrate);

    if (!SteamWorks_SetHTTPRequestContextValue(hRequest, pack)
        || !SteamWorks_SetHTTPCallbacks(hRequest, RV_OnDownloadCompleted))
    {
        delete pack;
        delete hRequest;
        RV_FinishViewTask(uuid);
        RV_ViewReply(client, "Replay View Failed");
        return;
    }

    if (gCV_Debug != null && gCV_Debug.BoolValue)
        LogMessage("[replay-vault] View download uuid=%s key=%s map=%s tickrate=%d", uuid, key, map, tickrate);

    if (!SteamWorks_SendHTTPRequest(hRequest))
    {
        delete pack;
        delete hRequest;
        RV_FinishViewTask(uuid);
        RV_ViewReply(client, "Replay View Failed");
    }
}

public void RV_OnDownloadCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful,
    EHTTPStatusCode eStatusCode, any data)
{
    DataPack pack = view_as<DataPack>(data);
    int clientUserId = pack.ReadCell();
    char uuid[64], key[RV_MAX_KEY_LENGTH], map[64], steamid64[32];
    char mode[16], timetype[16], date[RV_MAX_DATE_LENGTH], category[16];
    pack.ReadString(uuid, sizeof(uuid));
    pack.ReadString(key, sizeof(key));
    pack.ReadString(map, sizeof(map));
    int course = pack.ReadCell();
    pack.ReadString(steamid64, sizeof(steamid64));
    pack.ReadString(mode, sizeof(mode));
    pack.ReadString(timetype, sizeof(timetype));
    pack.ReadString(date, sizeof(date));
    int timeMs = pack.ReadCell();
    pack.ReadString(category, sizeof(category));
    int tickrate = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(clientUserId);
    int code = view_as<int>(eStatusCode);
    bool ok = !bFailure && bRequestSuccessful && code >= 200 && code < 300;

    char partPath[PLATFORM_MAX_PATH];
    RV_CachePartPathOf(uuid, partPath, sizeof(partPath));
    char cachePath[PLATFORM_MAX_PATH];
    RV_CachePathOf(uuid, cachePath, sizeof(cachePath));

    if (!ok)
    {
        if (FileExists(partPath)) DeleteFile(partPath);
        RV_FinishViewTask(uuid);
        if (client > 0 && IsClientInGame(client))
        {
            if (code == 404) RV_ViewReply(client, "Replay View Not Found");
            else RV_ViewReply(client, "Replay View Download Failed");
        }
        delete hRequest;
        return;
    }

    int size = 0;
    SteamWorks_GetHTTPResponseBodySize(hRequest, size);
    if (size <= 0 || size > RV_VIEW_MAX_DOWNLOAD_BYTES)
    {
        if (FileExists(partPath)) DeleteFile(partPath);
        RV_FinishViewTask(uuid);
        if (client > 0 && IsClientInGame(client)) RV_ViewReply(client, "Replay View Download Failed");
        delete hRequest;
        return;
    }

    // WriteHTTPResponseBodyToFile 是 SteamWorks 官方推荐的“响应体落盘”用法：
    // 在 completion 回调里调用，内部自行取 body。写完用 size 复核，失败即报错而非播放坏文件。
    bool written = SteamWorks_WriteHTTPResponseBodyToFile(hRequest, partPath);
    delete hRequest;
    if (!written || !FileExists(partPath) || FileSize(partPath) != size)
    {
        if (FileExists(partPath)) DeleteFile(partPath);
        RV_FinishViewTask(uuid);
        if (client > 0 && IsClientInGame(client)) RV_ViewReply(client, "Replay View Download Failed");
        return;
    }

    int replayType = ReplayType_Run, fileTickrate = 0;
    char fileMap[64];
    if (!RV_ParseReplayHeader(partPath, replayType, fileTickrate, fileMap, sizeof(fileMap)))
    {
        DeleteFile(partPath);
        RV_FinishViewTask(uuid);
        if (client > 0 && IsClientInGame(client)) RV_ViewReply(client, "Replay View Corrupt");
        return;
    }

    if (FileExists(cachePath) && !DeleteFile(cachePath))
    {
        LogError("[replay-vault] Failed to replace cache replay: %s", cachePath);
    }
    if (!RenameFile(cachePath, partPath))
    {
        // 跨设备/占用退化：复制后删 .part
        if (!RV_FileCopy(partPath, cachePath))
        {
            DeleteFile(partPath);
            RV_FinishViewTask(uuid);
            if (client > 0 && IsClientInGame(client)) RV_ViewReply(client, "Replay View Download Failed");
            return;
        }
        DeleteFile(partPath);
    }

    // 写缓存伴生 meta，之后本地命中无需再联网。
    ReplayStageMeta meta;
    strcopy(meta.Key, sizeof(meta.Key), key);
    strcopy(meta.Map, sizeof(meta.Map), map);
    meta.Course = course;
    strcopy(meta.SteamID64, sizeof(meta.SteamID64), steamid64);
    strcopy(meta.Mode, sizeof(meta.Mode), mode);
    strcopy(meta.TimeType, sizeof(meta.TimeType), timetype);
    strcopy(meta.Date, sizeof(meta.Date), date);
    meta.TimeMs = timeMs;
    meta.UserId = 0;
    meta.Attempts = 0;
    meta.NextRetry = 0;
    meta.Created = GetTime();
    strcopy(meta.Category, sizeof(meta.Category), category);
    meta.Tickrate = tickrate > 0 ? tickrate : fileTickrate;
    char metaPath[PLATFORM_MAX_PATH];
    RV_CacheMetaPathOf(uuid, metaPath, sizeof(metaPath));
    RV_WriteMeta(metaPath, meta);

    RV_FinishViewTask(uuid);
    if (client > 0 && IsClientInGame(client))
    {
        RV_PlayLocal(client, uuid, cachePath);
    }
    else if (gCV_Debug != null && gCV_Debug.BoolValue)
    {
        LogMessage("[replay-vault] Cached replay uuid=%s (client left before playback)", uuid);
    }
}

// =====[ LIST MENU ]=====

void RV_OpenReplayMenu(int client)
{
    if (!RV_CanList())
    {
        RV_ViewReply(client, "Replay View Menu Disabled");
        return;
    }

    char steamid64[32];
    if (!RV_GetSteamID64(client, steamid64, sizeof(steamid64)))
    {
        RV_ViewReply(client, "Replay View Failed");
        return;
    }

    char base[512], url[640];
    if (!RV_ViewerBaseUrl(base, sizeof(base)))
    {
        RV_ViewReply(client, "Replay View Disabled");
        return;
    }
    int limit = gCV_ViewLimit != null ? gCV_ViewLimit.IntValue : 20;
    FormatEx(url, sizeof(url), "%s/list?steamid64=%s&limit=%d", base, steamid64, limit);

    Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
    if (hRequest == null)
    {
        RV_ViewReply(client, "Replay View Menu Failed");
        return;
    }

    int timeoutSec = RV_GetTimeoutSeconds();
    SteamWorks_SetHTTPRequestNetworkActivityTimeout(hRequest, timeoutSec);
    SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(hRequest, timeoutSec * 1000);
    char apiKey[256];
    RV_ViewerApiKey(apiKey, sizeof(apiKey));
    SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-API-Key", apiKey);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));

    if (!SteamWorks_SetHTTPRequestContextValue(hRequest, pack)
        || !SteamWorks_SetHTTPCallbacks(hRequest, RV_OnListCompleted))
    {
        delete pack;
        delete hRequest;
        RV_ViewReply(client, "Replay View Menu Failed");
        return;
    }

    if (!SteamWorks_SendHTTPRequest(hRequest))
    {
        delete pack;
        delete hRequest;
        RV_ViewReply(client, "Replay View Menu Failed");
    }
}

public void RV_OnListCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful,
    EHTTPStatusCode eStatusCode, any data)
{
    DataPack pack = view_as<DataPack>(data);
    int clientUserId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(clientUserId);
    int code = view_as<int>(eStatusCode);
    bool ok = !bFailure && bRequestSuccessful && code >= 200 && code < 300;

    int size = 0;
    if (ok) SteamWorks_GetHTTPResponseBodySize(hRequest, size);
    if (!ok || size <= 0 || size > 262144)
    {
        delete hRequest;
        if (client > 0 && IsClientInGame(client)) RV_ViewReply(client, "Replay View Menu Failed");
        return;
    }

    char[] body = new char[size + 1];
    SteamWorks_GetHTTPResponseBodyData(hRequest, body, size + 1);
    body[size] = '\0';
    delete hRequest;

    if (client <= 0 || !IsClientInGame(client)) return;

    JSON_Object root = json_decode(body);
    if (root == null)
    {
        RV_ViewReply(client, "Replay View Menu Failed");
        return;
    }

    JSON_Array items = view_as<JSON_Array>(root.GetObject("items"));
    int count = items != null ? items.Length : 0;
    if (count <= 0)
    {
        root.Cleanup();
        RV_ViewReply(client, "Replay View No Replays");
        return;
    }

    Menu menu = new Menu(MenuHandler_ReplayList);
    menu.SetTitle("%T", "Replay View Menu Title", client);

    char uuid[64], label[128];
    for (int i = 0; i < count; i++)
    {
        JSON_Object item = items.GetObject(i);
        if (item == null) continue;
        uuid[0] = '\0';
        item.GetString("uuid", uuid, sizeof(uuid));
        if (uuid[0] == '\0') continue;
        RV_BuildListItemLabel(item, label, sizeof(label));
        menu.AddItem(uuid, label);
    }

    root.Cleanup();

    if (menu.ItemCount == 0)
    {
        delete menu;
        RV_ViewReply(client, "Replay View No Replays");
        return;
    }
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ReplayList(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_Select)
    {
        char uuid[64];
        menu.GetItem(param2, uuid, sizeof(uuid));
        RV_RequestView(param1, uuid);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

static void RV_BuildListItemLabel(JSON_Object item, char[] label, int maxlen)
{
    char category[16], map[64], mode[16], timetype[16], courseStr[16], jumptype[32];
    category[0] = '\0';
    map[0] = '\0';
    mode[0] = '\0';
    timetype[0] = '\0';
    courseStr[0] = '\0';
    jumptype[0] = '\0';
    item.GetString("category", category, sizeof(category));
    item.GetString("map", map, sizeof(map));
    item.GetString("mode", mode, sizeof(mode));
    item.GetString("timetype", timetype, sizeof(timetype));
    item.GetString("course_str", courseStr, sizeof(courseStr));
    item.GetString("jumptype", jumptype, sizeof(jumptype));

    if (StrEqual(category, "run"))
    {
        if (courseStr[0] == '\0') strcopy(courseStr, sizeof(courseStr), "main");
        FormatEx(label, maxlen, "%s %s %s %s", map, courseStr, mode, timetype);
    }
    else if (StrEqual(category, "jump"))
    {
        FormatEx(label, maxlen, "%s %s %s", map, mode, jumptype);
    }
    else
    {
        FormatEx(label, maxlen, "%s %s cheat", map, mode);
    }
}
