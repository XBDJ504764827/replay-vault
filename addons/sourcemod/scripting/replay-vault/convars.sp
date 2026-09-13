// convars.sp - replay_vault_* ConVars (idempotent via autoexecconfig)

ConVar gCV_Enabled;
ConVar gCV_Url;
ConVar gCV_Key;
ConVar gCV_Timeout;
ConVar gCV_Debug;
ConVar gCV_Chat;
ConVar gCV_AnnounceJumps;
ConVar gCV_RetryInterval;
ConVar gCV_StagingMaxAge;
ConVar gCV_ViewEnabled;
ConVar gCV_CacheMaxAge;
ConVar gCV_CacheMaxMB;
ConVar gCV_DownloadCooldown;
ConVar gCV_ViewLimit;

void RV_CreateConVars()
{
    AutoExecConfig_SetFile("replay-vault", "sourcemod");
    AutoExecConfig_SetCreateFile(true);

    gCV_Enabled = AutoExecConfig_CreateConVar("replay_vault_enabled", "1",
        "Total switch for replay-vault uploads (0=disabled)", _, true, 0.0, true, 1.0);
    gCV_Url = AutoExecConfig_CreateConVar("replay_vault_url", "",
        "Worker root URL (e.g. https://vault-worker.yourdomain.workers.dev). Empty disables uploads.");
    gCV_Key = AutoExecConfig_CreateConVar("replay_vault_key", "",
        "X-API-Key for Worker auth. Empty disables uploads.");
    gCV_Timeout = AutoExecConfig_CreateConVar("replay_vault_timeout", "60",
        "HTTP timeout seconds", _, true, 1.0, true, 300.0);
    gCV_Debug = AutoExecConfig_CreateConVar("replay_vault_debug", "0",
        "Debug logging (1=verbose)", _, true, 0.0, true, 1.0);
    gCV_Chat = AutoExecConfig_CreateConVar("replay_vault_chat", "1",
        "Announce UUID in chat after run upload (1=enabled)", _, true, 0.0, true, 1.0);
    gCV_AnnounceJumps = AutoExecConfig_CreateConVar("replay_vault_announce_jumps", "0",
        "Also announce jumps/cheaters uploads (1=enabled)", _, true, 0.0, true, 1.0);
    gCV_RetryInterval = AutoExecConfig_CreateConVar("replay_vault_retry_interval", "60",
        "Staging retry scan interval seconds (min 15)", _, true, 15.0, true, 3600.0);
    gCV_StagingMaxAge = AutoExecConfig_CreateConVar("replay_vault_staging_max_age", "24",
        "Hours before giving up on staged replay uploads (min 1)", _, true, 1.0, true, 168.0);

    gCV_ViewEnabled = AutoExecConfig_CreateConVar("replay_vault_view_enabled", "1",
        "Enable the in-game !rv <uuid> replay viewer (0=disabled)", _, true, 0.0, true, 1.0);
    gCV_CacheMaxAge = AutoExecConfig_CreateConVar("replay_vault_cache_max_age", "72",
        "Hours a locally cached replay is kept before eviction (min 1)", _, true, 1.0, true, 720.0);
    gCV_CacheMaxMB = AutoExecConfig_CreateConVar("replay_vault_cache_max_mb", "2048",
        "Total size cap of the replay cache in MB (0=unlimited)", _, true, 0.0, true, 102400.0);
    gCV_DownloadCooldown = AutoExecConfig_CreateConVar("replay_vault_download_cooldown", "5",
        "Seconds a player must wait between viewer requests", _, true, 0.0, true, 300.0);
    gCV_ViewLimit = AutoExecConfig_CreateConVar("replay_vault_view_limit", "20",
        "Replays listed in the !rv menu (1-100)", _, true, 1.0, true, 100.0);

    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();
}

bool RV_CanUpload()
{
    if (!gB_SteamWorksOK || gCV_Enabled == null || !gCV_Enabled.BoolValue)
    {
        return false;
    }
    if (gCV_Url == null || gCV_Key == null) return false;
    char url[512], key[256];
    gCV_Url.GetString(url, sizeof(url));
    gCV_Key.GetString(key, sizeof(key));
    TrimString(url);
    TrimString(key);
    return url[0] != '\0' && key[0] != '\0';
}

// In-game viewing only needs a reachable Worker; the public /replay route is
// unauthenticated. The !rv menu additionally needs the API key for /list.
bool RV_CanView()
{
    if (!gB_SteamWorksOK || gCV_ViewEnabled == null || !gCV_ViewEnabled.BoolValue) return false;
    if (gCV_Url == null) return false;
    char url[512];
    gCV_Url.GetString(url, sizeof(url));
    TrimString(url);
    return url[0] != '\0';
}

bool RV_CanList()
{
    if (!RV_CanView() || gCV_Key == null) return false;
    char key[256];
    gCV_Key.GetString(key, sizeof(key));
    TrimString(key);
    return key[0] != '\0';
}
