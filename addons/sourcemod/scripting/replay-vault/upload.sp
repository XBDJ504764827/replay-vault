// upload.sp - SteamWorks POST to Worker (Worker relay, no R2 signing in Pawn)

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
        RV_DeleteStagingFile(stagingPath);
        return;
    }

    if (gCV_Debug != null && gCV_Debug.BoolValue)
        LogMessage("[replay-vault] Uploading %s uuid=%s key=%s timeout=%ds", stagingPath, uuid, key, timeoutSec);

    if (!SteamWorks_SendHTTPRequest(hRequest))
    {
        LogError("[replay-vault] Failed to send HTTP request key=%s uuid=%s", key, uuid);
        delete pack;
        delete hRequest;
        RV_DeleteStagingFile(stagingPath);
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
    int code = view_as<int>(eStatusCode);
    bool is2xx = !bFailure && bRequestSuccessful && code >= 200 && code < 300;

    if (is2xx)
    {
        RV_DeleteStagingFile(stagingPath);
        bool isRun = StrContains(key, "/runs/") != -1;
        bool announce = isRun ? (gCV_Chat != null && gCV_Chat.BoolValue) : (gCV_AnnounceJumps != null && gCV_AnnounceJumps.BoolValue);
        if (announce)
        {
            int client = GetClientOfUserId(clientUserId);
            if (client > 0 && IsClientInGame(client) && !IsFakeClient(client))
            {
                if (GetFeatureStatus(FeatureType_Native, "GOKZ_PrintToChat") == FeatureStatus_Available)
                    GOKZ_PrintToChat(client, true, "%t", "Replay Uploaded", uuid);
                else
                    PrintToChat(client, "[replay-vault] %T", "Replay Uploaded", client, uuid);
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
        RV_DeleteStagingFile(stagingPath);
    }
    delete hRequest;
}
