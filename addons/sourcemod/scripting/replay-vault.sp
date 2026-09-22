#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <SteamWorks>

#include <movementapi>
#include <gokz/core>
#include <gokz/jumpstats>
#include <gokz/anticheat>
#include <gokz/replays>

#include <autoexecconfig>
#include <json>

#pragma newdecls required
#pragma semicolon 1

#include <replay-vault/version.inc>

public Plugin myinfo =
{
    name = "replay-vault",
    author = "XBDJ504764827",
    description = "Full replay backup to R2 (Worker relay) - all runs/jumps/cheaters by UUID",
    version = REPLAY_VAULT_VERSION,
    url = ""
};

// Current map lowercased for key building
char gC_CurrentMap[64];
bool gB_SteamWorksOK;
StringMap gM_CapturedReplays;

#include "replay-vault/convars.sp"
#include "replay-vault/helpers.sp"
#include "replay-vault/uuid.sp"
#include "replay-vault/upload.sp"
#include "replay-vault/cache.sp"
#include "replay-vault/viewer.sp"
#include "replay-vault/events.sp"
#include "replay-vault/recorder.sp"

// =====[ PLUGIN EVENTS ]=====

public void OnPluginStart()
{
    LoadTranslations("replay-vault.phrases");
    LoadTranslations("gokz-common.phrases");
    RV_CreateConVars();
    RV_UpdateDependencies();
    RV_InitEventState();
    RV_InitUploadState();
    RV_InitStagingScanner();
    RV_InitViewer();
    RV_InitCacheSweeper();
    RV_InitRecorder();
}

public void OnAllPluginsLoaded()
{
    RV_UpdateDependencies();
    RV_UpdateRecorderDeps();
    RV_RecRefreshCaptureGate();
    if (!gB_SteamWorksOK)
    {
        LogError("[replay-vault] SteamWorks extension is not loaded; uploads are disabled");
    }
    if (!LibraryExists("gokz-replays"))
    {
        LogMessage("[replay-vault] gokz-replays not found at load; replay forwards are unavailable");
    }
    if (!LibraryExists("movementapi"))
    {
        LogError("[replay-vault] movementapi not found; run recorder tick flags will be degraded");
    }
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "SteamWorks.ext", false) || StrEqual(name, "SteamWorks", false))
    {
        RV_UpdateDependencies();
        RV_RecRefreshCaptureGate();
    }
    if (StrEqual(name, "movementapi", false))
    {
        RV_UpdateRecorderDeps();
    }
    if (StrEqual(name, "movementapi", false))
    {
        RV_UpdateRecorderDeps();
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "SteamWorks.ext", false) || StrEqual(name, "SteamWorks", false))
    {
        gB_SteamWorksOK = false;
        RV_RecRefreshCaptureGate();
    }
    if (StrEqual(name, "movementapi", false))
    {
        RV_UpdateRecorderDeps();
    }
    if (StrEqual(name, "movementapi", false))
    {
        RV_UpdateRecorderDeps();
    }
}

public void OnMapStart()
{
    RV_OnMapStart();
    RV_RecOnMapStart();
}

public void OnPluginEnd()
{
    delete gM_CapturedReplays;
    RV_OnPluginEnd_Viewer();
    RV_ShutdownRecorder();
}

public void OnClientPutInServer(int client)
{
    RV_RecOnClientPutInServer(client);
}

public void OnClientDisconnect(int client)
{
    RV_RecOnClientDisconnect(client);
}

// =====[ GOKZ TIMER FORWARDS (record every completion) ]=====

public void GOKZ_OnTimerStart_Post(int client, int course)
{
    RV_RecOnTimerStart(client);
}

public void GOKZ_OnTimerEnd_Post(int client, int course, float time, int teleportsUsed)
{
    RV_RecOnTimerEnd(client, course, time, teleportsUsed);
}

public void GOKZ_OnTimerStopped(int client)
{
    RV_RecOnTimerStopped(client);
}

public void GOKZ_OnPause_Post(int client)
{
    RV_RecOnPause(client);
}

public void GOKZ_OnResume_Post(int client)
{
    RV_RecOnResume(client);
}

public void GOKZ_OnCountedTeleport_Post(int client)
{
    RV_RecOnCountedTeleport(client);
}

public Action GOKZ_RP_OnReplaySaved(int client, int replayType, const char[] map,
    int course, int timeType, float time, const char[] filePath, bool tempReplay)
{
    RV_OnReplaySaved(client, replayType, map, course, timeType, time, filePath, tempReplay);
    return Plugin_Continue;
}

// gokz-replays 已完成落盘（含其自身删除 temp 文件之前）；非空 filePath 表示该局
// 已走 GOKZ_RP_OnReplaySaved 上传，自建录制器据此跳过，避免重复上传。
public void GOKZ_RP_OnTimerEnd_Post(int client, const char[] filePath, int course,
    float time, int teleportsUsed)
{
    RV_RecOnUpstreamTimerEnd(client, filePath, course, time);
}

// Jumps / cheaters fallback (if gokz-replays forwards them via same forward, handled above;
// otherwise these forwards trigger scan fallback in events.sp)
public void GOKZ_DB_OnJumpstatPB(int client, int jumptype, int mode, float distance,
    int block, int strafes, float sync, float pre, float max, int airtime)
{
    RV_OnJumpstatPB(client, jumptype, mode, distance, block, strafes, sync, pre, max, airtime);
}

public void GOKZ_AC_OnPlayerSuspected(int client, ACReason reason, const char[] notes, const char[] stats)
{
    RV_OnCheaterSuspected(client, view_as<int>(reason));
}
