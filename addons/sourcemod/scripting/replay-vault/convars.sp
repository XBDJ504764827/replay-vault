// convars.sp - replay_vault_* ConVars (idempotent via autoexecconfig)

ConVar gCV_Enabled;
ConVar gCV_Url;
ConVar gCV_Key;
ConVar gCV_Timeout;
ConVar gCV_Debug;
ConVar gCV_Chat;
ConVar gCV_AnnounceJumps;

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
    char url[256], key[256];
    gCV_Url.GetString(url, sizeof(url));
    gCV_Key.GetString(key, sizeof(key));
    TrimString(url);
    TrimString(key);
    return url[0] != '\0' && key[0] != '\0';
}
