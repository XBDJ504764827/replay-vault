// recorder.sp - self-contained run recorder (no gokz-replays upstream changes)
//
// 需求：玩家完成地图时，无论是否破自己的纪录 / PB / WR，录像都要上传。
//
// 上游 gokz-replays 在玩家慢于自己 PB 时会停止录制并直接丢弃录像
// （GOKZ_LR_OnPBMissed -> ReplaySave_Disabled，GOKZ_OnTimerEnd_Recording 提前 return），
// 该局不会落盘、也不会触发 GOKZ_RP_OnReplaySaved，插件无法拿到文件。
//
// 因此本模块自行按 tick 录制整局，写成与 gokz-replays 完全一致的 v2 .replay，
// 再复用 staging 上传 / 本地缓存链路。
//
// 去重：gokz-replays 自己保存的录像（破纪录 / 破 PB）仍走 GOKZ_RP_OnReplaySaved
// 上传；这里通过 GOKZ_RP_OnTimerEnd_Post 得知「上游已落盘」，就不再重复上传。
//
// 缓冲结构对齐上游 recording.sp：
//   gA_RecPre  —— 常驻滚动 pre-run 环（最近 RP_PLAYBACK_BREATHER_TIME 秒），开局时复制进 run
//   gA_RecRun  —— 当前正在计时的这一局的 tick
//   gA_RecPost —— 已结束、仍在补录/等待定稿的那一局的 tick
// run / post 分离，所以「上一局还在 2s 定稿窗口、玩家已开下一局」时两局互不覆盖，
// 且上一局的 post-run 补录不会被截断。

#define RV_REC_FINALIZE_DELAY (RP_PLAYBACK_BREATHER_TIME + 0.5)

static ArrayList gA_RecRun[MAXPLAYERS + 1];   // 当前 run tick（ReplayTickData[]）
static ArrayList gA_RecPost[MAXPLAYERS + 1];  // 待定稿 run tick（含 post-run 补录）
static ArrayList gA_RecPre[MAXPLAYERS + 1];   // 滚动 pre-run 环
static int gI_RecPreTotal[MAXPLAYERS + 1];    // 环累计写入数（用于推算最旧位置）
static bool gB_RecActive[MAXPLAYERS + 1];     // 计时中
static bool gB_RecPost[MAXPLAYERS + 1];       // 结束后补录 / 等待定稿
static bool gB_RecPaused[MAXPLAYERS + 1];     // 计时暂停（与上游一致：暂停时不录制）
static bool gB_RecMovementProcessed[MAXPLAYERS + 1];
static bool gB_RecTeleportTick[MAXPLAYERS + 1];
static int gI_RecPendingTeleports[MAXPLAYERS + 1];
static float gF_RecSensitivity[MAXPLAYERS + 1];
static float gF_RecMYaw[MAXPLAYERS + 1];
static Handle gH_RecFinalize[MAXPLAYERS + 1];
static bool gB_RecMovementApiOK;
static bool gB_RecHitPerfOK;

// 一局完成的全部元数据；定稿时可能玩家已断开，所以必须在此刻快照。
enum struct RV_RecPending
{
    bool Valid;
    bool UpstreamSaved;
    int UserId;
    char MapKey[64];      // 小写 sanitized，仅用于 R2 键
    char MapDisplay[64];  // gokz-replays 原始 display name，写入录像头（播放端区分大小写）
    char SteamID64[32];
    int AccountID;
    char Alias[MAX_NAME_LENGTH];
    int Course;
    float Time;
    int TeleportsUsed;
    int Mode;
    int Style;
    float Tickrate;
    int MapFileSize;
    int ServerIP;
    int Timestamp;
    float Sensitivity;
    float MYaw;
    int Weapon;
    int Knife;
}

RV_RecPending gP_Rec[MAXPLAYERS + 1];

bool RV_RecEnabled()
{
    // 未配置 Worker / 总开关关闭时没必要录制（否则白占内存）。
    return gCV_RecordAll != null && gCV_RecordAll.BoolValue && RV_CanUpload();
}

// 单局 tick 上限（含 pre/post），默认 30 分钟，防长局吃内存。
int RV_RecMaxTicks()
{
    int minutes = gCV_RecordMaxMinutes != null ? gCV_RecordMaxMinutes.IntValue : 30;
    if (minutes <= 0) return RP_MAX_DURATION;

    float interval = GetTickInterval();
    int tickrate = interval > 0.0 ? RoundToZero(1.0 / interval) : 128;
    int ticks = minutes * 60 * tickrate;
    if (ticks <= 0 || ticks > RP_MAX_DURATION) return RP_MAX_DURATION;
    return ticks;
}

// 与 gokz-replays playback.sp 的 preAndPostRunTickCount 保持一致：
// 播放端把第 preTicks 个 tick 当作计时开始，录像头前必须带这么多 pre-run tick。
int RV_RecPreTicks()
{
    float interval = GetTickInterval();
    if (interval <= 0.0) return 0;
    return RoundToZero(RP_PLAYBACK_BREATHER_TIME / interval);
}

void RV_UpdateRecorderDeps()
{
    gB_RecMovementApiOK = GetFeatureStatus(FeatureType_Native, "Movement_GetTakeoffTick") == FeatureStatus_Available;
    gB_RecHitPerfOK = GetFeatureStatus(FeatureType_Native, "GOKZ_GetHitPerf") == FeatureStatus_Available;
}

void RV_InitRecorder()
{
    RV_UpdateRecorderDeps();
    for (int i = 0; i <= MaxClients; i++)
    {
        if (gA_RecRun[i] == null) gA_RecRun[i] = new ArrayList(sizeof(ReplayTickData));
        if (gA_RecPost[i] == null) gA_RecPost[i] = new ArrayList(sizeof(ReplayTickData));
        if (gA_RecPre[i] == null) gA_RecPre[i] = new ArrayList(sizeof(ReplayTickData));
        RV_RecResetClient(i);
    }
}

void RV_ShutdownRecorder()
{
    for (int i = 0; i <= MaxClients; i++)
    {
        if (gH_RecFinalize[i] != null)
        {
            KillTimer(gH_RecFinalize[i]);
            gH_RecFinalize[i] = null;
        }
        delete gA_RecRun[i];
        delete gA_RecPost[i];
        delete gA_RecPre[i];
        gA_RecRun[i] = null;
        gA_RecPost[i] = null;
        gA_RecPre[i] = null;
    }
}

void RV_RecResetTransient(int client)
{
    gB_RecActive[client] = false;
    gB_RecPaused[client] = false;
    gB_RecTeleportTick[client] = false;
    gI_RecPendingTeleports[client] = 0;
    gF_RecSensitivity[client] = -1.0;
    gF_RecMYaw[client] = -1.0;
}

// 丢弃 post 缓冲与待定稿状态（不结算）。
void RV_RecClearPost(int client)
{
    if (gH_RecFinalize[client] != null)
    {
        KillTimer(gH_RecFinalize[client]);
        gH_RecFinalize[client] = null;
    }
    gB_RecPost[client] = false;
    if (gA_RecPost[client] != null) gA_RecPost[client].Clear();
    gP_Rec[client].Valid = false;
    gP_Rec[client].UpstreamSaved = false;
}

void RV_RecResetClient(int client)
{
    RV_RecResetTransient(client);
    RV_RecClearPost(client);
    if (gA_RecRun[client] != null) gA_RecRun[client].Clear();
    if (gA_RecPre[client] != null) gA_RecPre[client].Clear();
    gI_RecPreTotal[client] = 0;
}

// =====[ LIFECYCLE ]=====

void RV_RecOnClientPutInServer(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client)) return;
    if (gA_RecRun[client] == null) gA_RecRun[client] = new ArrayList(sizeof(ReplayTickData));
    if (gA_RecPost[client] == null) gA_RecPost[client] = new ArrayList(sizeof(ReplayTickData));
    if (gA_RecPre[client] == null) gA_RecPre[client] = new ArrayList(sizeof(ReplayTickData));
    RV_RecResetClient(client);
    SDKHook(client, SDKHook_PostThinkPost, RV_RecOnPostThinkPost);
}

void RV_RecOnClientDisconnect(int client)
{
    if (client <= 0 || client > MaxClients) return;
    // 玩家在定稿前离开：录像已经录完，直接在这里补齐并上传。
    if (gP_Rec[client].Valid) RV_RecFinishPost(client);
    SDKUnhook(client, SDKHook_PostThinkPost, RV_RecOnPostThinkPost);
    RV_RecResetClient(client);
}

void RV_RecOnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (gP_Rec[i].Valid) RV_RecFinishPost(i);
        RV_RecResetClient(i);
    }
}

void RV_RecOnTimerStart(int client)
{
    if (!RV_RecEnabled() || !IsValidClient(client) || IsFakeClient(client)) return;

    // 注意：不清 post / gP_Rec —— 上一局可能还在 2s 定稿窗口里，
    // 两局分别用 gA_RecRun / gA_RecPost，互不覆盖。
    if (gA_RecRun[client] == null) gA_RecRun[client] = new ArrayList(sizeof(ReplayTickData));
    else gA_RecRun[client].Clear();

    gB_RecActive[client] = true;
    gB_RecPaused[client] = false;
    gB_RecTeleportTick[client] = false;
    gI_RecPendingTeleports[client] = 0;
    gF_RecSensitivity[client] = -1.0;
    gF_RecMYaw[client] = -1.0;

    RV_RecCopyPreTicks(client);

    QueryClientConVar(client, "sensitivity", RV_RecSensitivityCheck, client);
    QueryClientConVar(client, "m_yaw", RV_RecMYawCheck, client);
}

void RV_RecOnTimerEnd(int client, int course, float time, int teleportsUsed)
{
    if (client <= 0 || client > MaxClients) return;
    if (!gB_RecActive[client]) return;

    gB_RecActive[client] = false;

    // 极短局叠加：上一局还没定稿就结束下一局时，先结算上一局，腾出 post 缓冲。
    if (gB_RecPost[client]) RV_RecFinishPost(client);

    // run <-> post 交换（同上游）：post 拿到本局数据并继续补录，run 清空待下一局。
    ArrayList swap = gA_RecPost[client];
    gA_RecPost[client] = gA_RecRun[client];
    gA_RecRun[client] = swap;
    gA_RecRun[client].Clear();

    gB_RecPost[client] = true;

    gP_Rec[client].Valid = true;
    gP_Rec[client].UpstreamSaved = false;
    gP_Rec[client].UserId = GetClientUserId(client);
    strcopy(gP_Rec[client].MapKey, sizeof(gP_Rec[].MapKey), gC_CurrentMap);

    char display[64];
    GetCurrentMapDisplayName(display, sizeof(display));
    strcopy(gP_Rec[client].MapDisplay, sizeof(gP_Rec[].MapDisplay), display);

    if (!RV_GetSteamID64(client, gP_Rec[client].SteamID64, sizeof(gP_Rec[].SteamID64)))
    {
        LogError("[replay-vault] Cannot get SteamID64 while finalizing recorded run, dropping");
        RV_RecClearPost(client);
        return;
    }

    gP_Rec[client].AccountID = GetSteamAccountID(client);
    GetClientName(client, gP_Rec[client].Alias, sizeof(gP_Rec[].Alias));
    gP_Rec[client].Course = course;
    gP_Rec[client].Time = time;
    gP_Rec[client].TeleportsUsed = teleportsUsed;
    gP_Rec[client].Mode = GOKZ_GetCoreOption(client, Option_Mode);
    gP_Rec[client].Style = GOKZ_GetCoreOption(client, Option_Style);

    float interval = GetTickInterval();
    gP_Rec[client].Tickrate = interval > 0.0 ? 1.0 / interval : 128.0;
    gP_Rec[client].MapFileSize = GetCurrentMapFileSize();

    ConVar hostip = FindConVar("hostip");
    gP_Rec[client].ServerIP = hostip != null ? hostip.IntValue : 0;
    gP_Rec[client].Timestamp = GetTime();
    gP_Rec[client].Sensitivity = gF_RecSensitivity[client];
    gP_Rec[client].MYaw = gF_RecMYaw[client];
    gP_Rec[client].Weapon = RV_RecWeaponSlotDefIndex(client, CS_SLOT_SECONDARY);
    gP_Rec[client].Knife = RV_RecWeaponSlotDefIndex(client, CS_SLOT_KNIFE);

    RV_RecScheduleFinalize(client);
}

void RV_RecOnTimerStopped(int client)
{
    if (client <= 0 || client > MaxClients) return;
    // 放弃计时不算完成：只丢当前 run，不影响仍在定稿窗口的上一局。
    gB_RecActive[client] = false;
    if (gA_RecRun[client] != null) gA_RecRun[client].Clear();
}

void RV_RecOnPause(int client)
{
    if (client > 0 && client <= MaxClients) gB_RecPaused[client] = true;
}

void RV_RecOnResume(int client)
{
    if (client > 0 && client <= MaxClients) gB_RecPaused[client] = false;
}

void RV_RecOnCountedTeleport(int client)
{
    if (client <= 0 || client > MaxClients) return;
    if (gB_RecPaused[client]) gI_RecPendingTeleports[client]++;
    else gB_RecTeleportTick[client] = true;
}

void RV_RecScheduleFinalize(int client)
{
    if (gH_RecFinalize[client] != null)
    {
        KillTimer(gH_RecFinalize[client]);
        gH_RecFinalize[client] = null;
    }

    DataPack dp = new DataPack();
    dp.WriteCell(gP_Rec[client].UserId);
    gH_RecFinalize[client] = CreateTimer(RV_REC_FINALIZE_DELAY, Timer_RecFinalize, dp,
        TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
    if (gH_RecFinalize[client] == null)
    {
        delete dp;
        LogError("[replay-vault] Failed to schedule recorded run finalize, uploading immediately");
        RV_RecFinishPost(client);
    }
}

public Action Timer_RecFinalize(Handle timer, DataPack dp)
{
    dp.Reset();
    int userId = dp.ReadCell();
    int client = GetClientOfUserId(userId);
    if (client > 0 && client <= MaxClients)
    {
        gH_RecFinalize[client] = null; // 定时器句柄由 TIMER_DATA_HNDL_CLOSE 关闭
        RV_RecFinishPost(client);
    }
    return Plugin_Stop;
}

// 定稿 post 缓冲：上游已保存则跳过（避免重复上传），否则自己写文件 + 上传。
void RV_RecFinishPost(int client)
{
    if (client <= 0 || client > MaxClients) return;

    if (gH_RecFinalize[client] != null)
    {
        KillTimer(gH_RecFinalize[client]);
        gH_RecFinalize[client] = null;
    }

    bool valid = gP_Rec[client].Valid;
    bool upstreamSaved = gP_Rec[client].UpstreamSaved;

    gB_RecPost[client] = false;

    if (valid && !upstreamSaved)
    {
        RV_RecWriteAndUpload(client);
    }
    else if (valid && upstreamSaved && gCV_Debug != null && gCV_Debug.BoolValue)
    {
        LogMessage("[replay-vault] gokz-replays already stored this run, skip recorder upload");
    }

    if (gA_RecPost[client] != null) gA_RecPost[client].Clear();
    gP_Rec[client].Valid = false;
    gP_Rec[client].UpstreamSaved = false;
}

// gokz-replays 的 breather 结束后会告知落盘路径；非空说明该局已由上游保存并上传。
void RV_RecOnUpstreamTimerEnd(int client, const char[] filePath, int course, float time)
{
    if (client <= 0 || client > MaxClients) return;
    if (!gP_Rec[client].Valid || filePath[0] == '\0') return;
    if (gP_Rec[client].Course != course) return;
    if (FloatAbs(gP_Rec[client].Time - time) > 0.05) return;
    gP_Rec[client].UpstreamSaved = true;
}

// =====[ PRE-RUN RING ]=====

void RV_RecPrePush(int client, ReplayTickData tick)
{
    int cap = RV_RecPreTicks();
    if (cap <= 0 || gA_RecPre[client] == null) return;

    int total = gI_RecPreTotal[client];
    if (gA_RecPre[client].Length < cap)
    {
        gA_RecPre[client].PushArray(tick);
    }
    else
    {
        gA_RecPre[client].SetArray(total % cap, tick);
    }
    gI_RecPreTotal[client] = total + 1;
}

// 把滚动环里的 pre-run tick 复制到 run 缓冲开头，**始终补齐 cap 个**
// （与上游一致：环里不足时用最旧的 tick 复制补头，保证播放端偏移量恒定）。
void RV_RecCopyPreTicks(int client)
{
    ArrayList pre = gA_RecPre[client];
    ArrayList run = gA_RecRun[client];
    if (pre == null || run == null) return;

    int cap = RV_RecPreTicks();
    int count = pre.Length;
    if (cap <= 0 || count == 0) return;

    bool full = count >= cap;
    int total = gI_RecPreTotal[client];
    int oldest = full ? (total % cap) : 0;

    ReplayTickData tick;
    int written = 0;
    for (int i = 0; i < cap - count && written < cap; i++)
    {
        pre.GetArray(oldest, tick);
        run.PushArray(tick);
        written++;
    }
    for (int i = 0; i < count && written < cap; i++)
    {
        pre.GetArray(full ? ((oldest + i) % count) : i, tick);
        run.PushArray(tick);
        written++;
    }
}

// =====[ TICK CAPTURE ]=====

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3],
    float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (client > 0 && client <= MaxClients)
    {
        gB_RecMovementProcessed[client] = false;
    }
    return Plugin_Continue;
}

public void RV_RecOnPostThinkPost(int client)
{
    if (client > 0 && client <= MaxClients)
    {
        gB_RecMovementProcessed[client] = true;
    }
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3],
    const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
    if (client <= 0 || client > MaxClients) return;
    RV_RecCaptureTick(client, buttons, tickcount, vel, mouse);
}

void RV_RecCaptureTick(int client, int buttons, int tickCount, const float vel[3], const int mouse[2])
{
    if (!gB_RecMovementProcessed[client]) return;
    if (!IsValidClient(client) || IsFakeClient(client) || !IsPlayerAlive(client)) return;
    if (gB_RecPaused[client]) return;

    ReplayTickData tick;
    tick.deltaFlags = 0;
    tick.deltaFlags2 = 0;
    Movement_GetOrigin(client, tick.origin);
    tick.mouse = mouse;
    tick.vel = vel;
    Movement_GetVelocity(client, tick.velocity);
    Movement_GetEyeAngles(client, tick.angles);
    tick.flags = RV_RecEncodeFlags(client, buttons, tickCount);
    tick.packetsPerSecond = GetClientAvgPackets(client, NetFlow_Incoming);
    tick.laggedMovementValue = GetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue");
    tick.buttonsForced = GetEntProp(client, Prop_Data, "m_afButtonForced");

    int maxTicks = RV_RecMaxTicks();
    RV_RecPrePush(client, tick);

    if (gB_RecActive[client] && gA_RecRun[client] != null
        && gA_RecRun[client].Length < maxTicks)
    {
        gA_RecRun[client].PushArray(tick);
    }

    if (gB_RecPost[client] && gA_RecPost[client] != null
        && gA_RecPost[client].Length < maxTicks)
    {
        gA_RecPost[client].PushArray(tick);
    }

    // 与上游一致：本 tick 用完后再清 teleport 标记。
    if (gB_RecTeleportTick[client]) gB_RecTeleportTick[client] = false;
    if (gI_RecPendingTeleports[client] > 0) gI_RecPendingTeleports[client]--;
}

int RV_RecEncodeFlags(int client, int buttons, int tickCount)
{
    int flags = view_as<int>(Movement_GetMovetype(client)) & RP_MOVETYPE_MASK;
    int clientFlags = GetEntityFlags(client);

    RV_RecSetBit(flags, 4, IsBitSetInt(buttons, IN_ATTACK));
    RV_RecSetBit(flags, 5, IsBitSetInt(buttons, IN_ATTACK2));
    RV_RecSetBit(flags, 6, IsBitSetInt(buttons, IN_JUMP));
    RV_RecSetBit(flags, 7, IsBitSetInt(buttons, IN_DUCK));
    RV_RecSetBit(flags, 8, IsBitSetInt(buttons, IN_FORWARD));
    RV_RecSetBit(flags, 9, IsBitSetInt(buttons, IN_BACK));
    RV_RecSetBit(flags, 10, IsBitSetInt(buttons, IN_LEFT));
    RV_RecSetBit(flags, 11, IsBitSetInt(buttons, IN_RIGHT));
    RV_RecSetBit(flags, 12, IsBitSetInt(buttons, IN_MOVELEFT));
    RV_RecSetBit(flags, 13, IsBitSetInt(buttons, IN_MOVERIGHT));
    RV_RecSetBit(flags, 14, IsBitSetInt(buttons, IN_RELOAD));
    RV_RecSetBit(flags, 15, IsBitSetInt(buttons, IN_SPEED));
    RV_RecSetBit(flags, 16, IsBitSetInt(buttons, IN_USE));
    RV_RecSetBit(flags, 17, IsBitSetInt(buttons, IN_BULLRUSH));
    RV_RecSetBit(flags, 18, IsBitSetInt(clientFlags, FL_ONGROUND));
    RV_RecSetBit(flags, 19, IsBitSetInt(clientFlags, FL_DUCKING));
    RV_RecSetBit(flags, 20, IsBitSetInt(clientFlags, FL_SWIM));
    RV_RecSetBit(flags, 21, GetEntProp(client, Prop_Data, "m_nWaterLevel") != 0);
    RV_RecSetBit(flags, 22, gB_RecTeleportTick[client] || gI_RecPendingTeleports[client] > 0);
    if (gB_RecMovementApiOK)
    {
        RV_RecSetBit(flags, 23, Movement_GetTakeoffTick(client) == tickCount);
    }
    if (gB_RecHitPerfOK)
    {
        RV_RecSetBit(flags, 24, GOKZ_GetHitPerf(client));
    }
    RV_RecSetBit(flags, 25, RV_RecIsCurrentWeaponSecondary(client));
    return flags;
}

void RV_RecSetBit(int &value, int offset, bool set)
{
    if (set) value |= (1 << offset);
}

bool IsBitSetInt(int value, int bit)
{
    return (value & bit) != 0;
}

int RV_RecWeaponSlotDefIndex(int client, int slot)
{
    int entity = GetPlayerWeaponSlot(client, slot);
    if (entity == -1) return -1;
    return GetEntProp(entity, Prop_Send, "m_iItemDefinitionIndex");
}

bool RV_RecIsCurrentWeaponSecondary(int client)
{
    int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    int secondary = GetPlayerWeaponSlot(client, CS_SLOT_SECONDARY);
    return active != -1 && active == secondary;
}

public void RV_RecSensitivityCheck(QueryCookie cookie, int client, ConVarQueryResult result,
    const char[] cvarName, const char[] cvarValue, any value)
{
    if (client > 0 && client <= MaxClients && IsClientInGame(client))
    {
        gF_RecSensitivity[client] = StringToFloat(cvarValue);
    }
}

public void RV_RecMYawCheck(QueryCookie cookie, int client, ConVarQueryResult result,
    const char[] cvarName, const char[] cvarValue, any value)
{
    if (client > 0 && client <= MaxClients && IsClientInGame(client))
    {
        gF_RecMYaw[client] = StringToFloat(cvarValue);
    }
}

// =====[ WRITE + UPLOAD ]=====

void RV_RecWriteAndUpload(int client)
{
    if (!RV_CanUpload()) return;
    ArrayList ticks = gA_RecPost[client];
    if (ticks == null || ticks.Length <= 0) return;

    int tickCount = ticks.Length;
    int preTicks = RV_RecPreTicks();

    // 录满上限即视为截断：把头部 Time 收敛到实际录到的长度，否则播放端
    // botTimeTicks 永远到不了，结束音 / 计时不会触发。
    bool truncated = tickCount >= RV_RecMaxTicks();
    float runTime = gP_Rec[client].Time;
    if (truncated)
    {
        float interval = GetTickInterval();
        int recordedRunTicks = tickCount - preTicks;
        if (recordedRunTicks < 0) recordedRunTicks = 0;
        runTime = recordedRunTicks * interval;
    }

    char courseStr[16], modeStr[16], timetypeStr[16], date[RV_MAX_DATE_LENGTH];
    char uuid[64], key[RV_MAX_KEY_LENGTH];

    int timeType = GOKZ_GetTimeTypeEx(gP_Rec[client].TeleportsUsed);
    RV_CourseToString(gP_Rec[client].Course, courseStr, sizeof(courseStr));
    RV_ModeToString(gP_Rec[client].Mode, modeStr, sizeof(modeStr));
    RV_TimeTypeToString(timeType, timetypeStr, sizeof(timetypeStr));
    RV_FormatDate(GetTime(), date, sizeof(date));
    RV_GenerateUUID(uuid, sizeof(uuid));
    RV_BuildRunKey(gP_Rec[client].MapKey, courseStr, gP_Rec[client].SteamID64, modeStr,
        timetypeStr, date, uuid, key, sizeof(key));

    if (!RV_EnsureDir(RV_STAGING_DIR))
    {
        LogError("[replay-vault] Failed to create staging dir for recorded run");
        return;
    }

    char dir[PLATFORM_MAX_PATH], stagingPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), RV_STAGING_DIR);
    FormatEx(stagingPath, sizeof(stagingPath), "%s/%s.replay", dir, uuid);

    if (!RV_RecWriteReplayFile(client, stagingPath, runTime))
    {
        LogError("[replay-vault] Failed to write recorded replay uuid=%s", uuid);
        if (FileExists(stagingPath)) DeleteFile(stagingPath);
        return;
    }

    int timeMs = RoundToNearest(runTime * 1000.0);
    if (gCV_Debug != null && gCV_Debug.BoolValue)
    {
        LogMessage("[replay-vault] Recorded run ticks=%d pre=%d truncated=%d uuid=%s key=%s",
            tickCount, preTicks, truncated ? 1 : 0, uuid, key);
    }

    RV_UploadFile(stagingPath, key, uuid, gP_Rec[client].MapKey, gP_Rec[client].Course,
        gP_Rec[client].SteamID64, modeStr, timetypeStr, date, timeMs, gP_Rec[client].UserId);
}

// 写出与 gokz-replays v2 完全一致的二进制（头字段顺序 / float 位模式 / delta 压缩）。
bool RV_RecWriteReplayFile(int client, const char[] path, float runTime)
{
    ArrayList ticks = gA_RecPost[client];
    if (ticks == null) return false;
    int tickCount = ticks.Length;
    if (tickCount <= 0) return false;

    File file = OpenFile(path, "wb");
    if (file == null) return false;

    // General header
    file.WriteInt32(RP_MAGIC_NUMBER);
    file.WriteInt8(RP_FORMAT_VERSION);
    file.WriteInt8(ReplayType_Run);
    file.WriteInt8(strlen(GOKZ_VERSION));
    file.WriteString(GOKZ_VERSION, false);
    file.WriteInt8(strlen(gP_Rec[client].MapDisplay));
    file.WriteString(gP_Rec[client].MapDisplay, false);
    file.WriteInt32(gP_Rec[client].MapFileSize);
    file.WriteInt32(gP_Rec[client].ServerIP);
    file.WriteInt32(gP_Rec[client].Timestamp);
    file.WriteInt8(strlen(gP_Rec[client].Alias));
    file.WriteString(gP_Rec[client].Alias, false);
    file.WriteInt32(gP_Rec[client].AccountID);
    file.WriteInt8(gP_Rec[client].Mode);
    file.WriteInt8(gP_Rec[client].Style);
    file.WriteInt32(view_as<int>(gP_Rec[client].Sensitivity));
    file.WriteInt32(view_as<int>(gP_Rec[client].MYaw));
    file.WriteInt32(view_as<int>(gP_Rec[client].Tickrate));
    file.WriteInt32(tickCount);
    file.WriteInt32(gP_Rec[client].Weapon);
    file.WriteInt32(gP_Rec[client].Knife);

    // Run header
    file.WriteInt32(view_as<int>(runTime));
    file.WriteInt8(gP_Rec[client].Course);
    file.WriteInt32(gP_Rec[client].TeleportsUsed);

    // Tick data (delta compressed, identical to gokz-replays WriteTickDataToFile)
    ReplayTickData tick;
    ReplayTickData prevTick;
    any current[RP_V2_TICK_DATA_BLOCKSIZE];
    any previous[RP_V2_TICK_DATA_BLOCKSIZE];
    for (int i = 0; i < tickCount; i++)
    {
        ticks.GetArray(i, tick);
        ticks.GetArray(IntMax(0, i - 1), prevTick);
        RV_RecTickToArray(tick, current);
        RV_RecTickToArray(prevTick, previous);

        int deltaFlags = (1 << RPDELTA_DELTAFLAGS);
        if (i == 0)
        {
            deltaFlags = (1 << RP_V2_TICK_DATA_BLOCKSIZE) - 1;
        }
        else
        {
            for (int j = 1; j < sizeof(current); j++)
            {
                if (current[j] ^ previous[j]) deltaFlags |= (1 << j);
            }
        }

        file.WriteInt32(deltaFlags);
        for (int j = 1; j < sizeof(current); j++)
        {
            if (deltaFlags & (1 << j)) file.WriteInt32(current[j]);
        }
    }

    delete file;
    return true;
}

// 必须与 ReplayTickData 布局严格一致（同 gokz-replays TickDataToArray）。
void RV_RecTickToArray(ReplayTickData tick, any result[RP_V2_TICK_DATA_BLOCKSIZE])
{
    result[0]  = tick.deltaFlags;
    result[1]  = tick.deltaFlags2;
    result[2]  = tick.vel[0];
    result[3]  = tick.vel[1];
    result[4]  = tick.vel[2];
    result[5]  = tick.mouse[0];
    result[6]  = tick.mouse[1];
    result[7]  = tick.origin[0];
    result[8]  = tick.origin[1];
    result[9]  = tick.origin[2];
    result[10] = tick.angles[0];
    result[11] = tick.angles[1];
    result[12] = tick.angles[2];
    result[13] = tick.velocity[0];
    result[14] = tick.velocity[1];
    result[15] = tick.velocity[2];
    result[16] = tick.flags;
    result[17] = tick.packetsPerSecond;
    result[18] = tick.laggedMovementValue;
    result[19] = tick.buttonsForced;
}
