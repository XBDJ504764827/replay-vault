#include <sourcemod>
#include <sdktools>
#include <SteamWorks>

#include <gokz/core>
#include <gokz/jumpstats>
#include <gokz/anticheat>
#include <gokz/replays>

#include <autoexecconfig>

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
#include "replay-vault/events.sp"

// =====[ PLUGIN EVENTS ]=====

public void OnPluginStart()
{
    LoadTranslations("replay-vault.phrases");
    LoadTranslations("gokz-common.phrases");
    RV_CreateConVars();
    RV_UpdateDependencies();
    RV_InitEventState();
}

public void OnAllPluginsLoaded()
{
    RV_UpdateDependencies();
    if (!gB_SteamWorksOK)
    {
        LogError("[replay-vault] SteamWorks extension is not loaded; uploads are disabled");
    }
    if (!LibraryExists("gokz-replays"))
    {
        LogMessage("[replay-vault] gokz-replays not found at load; replay forwards are unavailable");
    }
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "SteamWorks.ext", false) || StrEqual(name, "SteamWorks", false))
    {
        RV_UpdateDependencies();
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "SteamWorks.ext", false) || StrEqual(name, "SteamWorks", false))
    {
        gB_SteamWorksOK = false;
    }
}

public void OnMapStart()
{
    RV_OnMapStart();
}

public void OnPluginEnd()
{
    delete gM_CapturedReplays;
}

public Action GOKZ_RP_OnReplaySaved(int client, int replayType, const char[] map,
    int course, int timeType, float time, const char[] filePath, bool tempReplay)
{
    RV_OnReplaySaved(client, replayType, map, course, timeType, time, filePath, tempReplay);
    return Plugin_Continue;
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
