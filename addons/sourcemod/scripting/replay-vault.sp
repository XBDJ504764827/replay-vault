#include <sourcemod>
#include <sdktools>
#include <SteamWorks>

#include <gokz/core>
#include <gokz/replays>

#include <autoexecconfig>

#pragma newdecls required
#pragma semicolon 1

#include <replay-vault/version.inc>

public Plugin myinfo =
{
    name = "replay-vault",
    author = "cngokz",
    description = "Full replay backup to R2 (Worker relay) - all runs/jumps/cheaters by UUID",
    version = REPLAY_VAULT_VERSION,
    url = "https://github.com/cngokz/replay-vault"
};

// Current map lowercased for key building
char gC_CurrentMap[64];

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
}

public void OnAllPluginsLoaded()
{
    if (!LibraryExists("gokz-replays"))
    {
        LogMessage("[replay-vault] gokz-replays not found at load, uploads will be queued until available");
    }
}

public void OnMapStart()
{
    RV_OnMapStart();
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

public void GOKZ_AC_OnPlayerSuspected(int client, int reason)
{
    RV_OnCheaterSuspected(client, reason);
}
