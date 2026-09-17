// cache.sp - local replay cache
//
// 上传成功后把 staging/{uuid}.replay + .meta 同盘 RenameFile 进 cache/（零拷贝），
// 下载回来的录像也落在这；玩家用 UUID 回看时优先命中本地，命中不了才回源 R2。
// 淘汰策略：默认 72 小时（对齐 R2 3 天生命周期）+ 可选总容量上限，超龄/超限删最旧。

#define RV_CACHE_SWEEP_INTERVAL 600.0
#define RV_CACHE_SWEEP_MAX_DELETIONS 200 // 单次扫描最多删除的文件数，限制主线程耗时
#define RV_CACHE_ORPHAN_MAX_AGE 3600     // 无主 .part/.meta 的最长保留（秒）

void RV_InitCacheSweeper()
{
    RV_EnsureCacheDir();
    CreateTimer(RV_CACHE_SWEEP_INTERVAL, Timer_CacheSweep, _, TIMER_REPEAT);
}

bool RV_EnsureCacheDir()
{
    if (!RV_EnsureDir(RV_CACHE_DIR))
    {
        LogError("[replay-vault] Failed to create replay cache directory: %s", RV_CACHE_DIR);
        return false;
    }
    return true;
}

void RV_CachePathOf(const char[] uuid, char[] output, int maxlen)
{
    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), RV_CACHE_DIR);
    FormatEx(output, maxlen, "%s/%s.replay", dir, uuid);
}

void RV_CacheMetaPathOf(const char[] uuid, char[] output, int maxlen)
{
    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), RV_CACHE_DIR);
    FormatEx(output, maxlen, "%s/%s.meta", dir, uuid);
}

void RV_CachePartPathOf(const char[] uuid, char[] output, int maxlen)
{
    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), RV_CACHE_DIR);
    FormatEx(output, maxlen, "%s/%s.part", dir, uuid);
}

bool RV_CacheReplayExists(const char[] uuid, char[] pathOut, int maxlen)
{
    RV_CachePathOf(uuid, pathOut, maxlen);
    return FileExists(pathOut);
}

void RV_DeleteCachePair(const char[] uuid)
{
    char path[PLATFORM_MAX_PATH];
    RV_CachePathOf(uuid, path, sizeof(path));
    if (FileExists(path) && !DeleteFile(path))
    {
        LogError("[replay-vault] Failed to delete cache replay: %s", path);
    }
    RV_CacheMetaPathOf(uuid, path, sizeof(path));
    if (FileExists(path) && !DeleteFile(path))
    {
        LogError("[replay-vault] Failed to delete cache meta: %s", path);
    }
}

// staging 上传成功后的归宿：同盘改名进缓存；改名失败退化为复制+删除。
void RV_PromoteToCache(const char[] stagingPath)
{
    if (stagingPath[0] == '\0' || !FileExists(stagingPath)) return;
    if (!RV_EnsureCacheDir())
    {
        RV_DeleteStagedPair(stagingPath);
        return;
    }

    char fileName[PLATFORM_MAX_PATH], uuid[64];
    RV_GetFileName(stagingPath, fileName, sizeof(fileName));
    strcopy(uuid, sizeof(uuid), fileName);
    int len = strlen(uuid);
    if (len <= RV_REPLAY_SUFFIX_LEN
        || strcmp(uuid[len - RV_REPLAY_SUFFIX_LEN], ".replay", false) != 0)
    {
        RV_DeleteStagedPair(stagingPath);
        return;
    }
    uuid[len - RV_REPLAY_SUFFIX_LEN] = '\0';

    char destReplay[PLATFORM_MAX_PATH], destMeta[PLATFORM_MAX_PATH];
    RV_CachePathOf(uuid, destReplay, sizeof(destReplay));
    RV_CacheMetaPathOf(uuid, destMeta, sizeof(destMeta));

    if (FileExists(destReplay))
    {
        RV_DeleteStagedPair(stagingPath);
        return;
    }

    char srcMeta[PLATFORM_MAX_PATH];
    RV_MetaPathOf(stagingPath, srcMeta, sizeof(srcMeta));
    if (FileExists(srcMeta) && !RenameFile(destMeta, srcMeta))
    {
        ReplayStageMeta meta;
        if (RV_ReadMeta(srcMeta, meta))
        {
            RV_WriteMeta(destMeta, meta);
        }
    }

    if (RenameFile(destReplay, stagingPath))
    {
        if (gCV_Debug != null && gCV_Debug.BoolValue)
            LogMessage("[replay-vault] Promoted replay to cache uuid=%s", uuid);
        return;
    }

    if (RV_FileCopy(stagingPath, destReplay))
    {
        RV_DeleteStagedPair(stagingPath);
        return;
    }

    LogError("[replay-vault] Failed to promote replay to cache uuid=%s", uuid);
    RV_DeleteStagedPair(stagingPath);
}

public Action Timer_CacheSweep(Handle timer)
{
    RV_SweepCache();
    return Plugin_Continue;
}

void RV_SweepCache()
{
    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), RV_CACHE_DIR);
    if (!DirExists(dir)) return;

    int maxAgeSec = (gCV_CacheMaxAge != null ? gCV_CacheMaxAge.IntValue : 72) * 3600;
    int maxBytes = (gCV_CacheMaxMB != null ? gCV_CacheMaxMB.IntValue : 2048);
    if (maxBytes > 0) maxBytes *= 1024 * 1024;
    int now = GetTime();

    ArrayList entries = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH + 16));
    int total = 0, deleted = 0;
    char deletedUuid[64];

    DirectoryListing listing = OpenDirectory(dir);
    if (listing == null)
    {
        delete entries;
        return;
    }

    char entry[PLATFORM_MAX_PATH], full[PLATFORM_MAX_PATH], line[PLATFORM_MAX_PATH + 32];
    FileType fileType;
    while (listing.GetNext(entry, sizeof(entry), fileType))
    {
        if (fileType != FileType_File) continue;
        FormatEx(full, sizeof(full), "%s/%s", dir, entry);
        int entryLen = strlen(entry);

        bool isReplay = entryLen > RV_REPLAY_SUFFIX_LEN
            && strcmp(entry[entryLen - RV_REPLAY_SUFFIX_LEN], ".replay", false) == 0;
        if (isReplay)
        {
            int modified = GetFileTime(full, FileTime_LastChange);
            int size = FileSize(full);
            if (modified < 0 || size <= 0)
            {
                DeleteFile(full);
                deleted++;
                continue;
            }
            if (now - modified > maxAgeSec)
            {
                strcopy(deletedUuid, sizeof(deletedUuid), entry);
                deletedUuid[entryLen - RV_REPLAY_SUFFIX_LEN] = '\0';
                RV_DeleteCachePair(deletedUuid);
                deleted++;
                continue;
            }
            total += size;
            // "mtime|path"：定宽 mtime 前缀让 Sort_String 直接得到最旧优先
            FormatEx(line, sizeof(line), "%010d|%s", modified, full);
            entries.PushString(line);
            continue;
        }

        bool isPart = entryLen > RV_META_SUFFIX_LEN
            && strcmp(entry[entryLen - RV_META_SUFFIX_LEN], ".part", false) == 0;
        bool isMeta = !isPart && entryLen > RV_META_SUFFIX_LEN
            && strcmp(entry[entryLen - RV_META_SUFFIX_LEN], ".meta", false) == 0;
        if (!isPart && !isMeta) continue;

        int modified = GetFileTime(full, FileTime_LastChange);
        if (modified < 0 || now - modified <= RV_CACHE_ORPHAN_MAX_AGE) continue;

        if (isMeta)
        {
            // 有正主 .replay 就留着，由 .replay 那一轮统一删
            char base[PLATFORM_MAX_PATH], owner[PLATFORM_MAX_PATH];
            strcopy(base, sizeof(base), full);
            base[strlen(base) - RV_META_SUFFIX_LEN] = '\0';
            FormatEx(owner, sizeof(owner), "%s.replay", base);
            if (FileExists(owner)) continue;
        }
        DeleteFile(full);
        deleted++;
    }
    delete listing;

    if (maxBytes > 0 && total > maxBytes && entries.Length > 0)
    {
        SortADTArray(entries, Sort_Ascending, Sort_String);
        int i = 0;
        while (total > maxBytes && i < entries.Length && deleted < RV_CACHE_SWEEP_MAX_DELETIONS)
        {
            entries.GetString(i, line, sizeof(line));
            int bar = FindCharInString(line, '|');
            i++;
            if (bar == -1) continue;

            char path[PLATFORM_MAX_PATH];
            strcopy(path, sizeof(path), line[bar + 1]);
            if (!FileExists(path)) continue;

            int size = FileSize(path);
            if (!DeleteFile(path)) continue;
            total -= (size > 0 ? size : 0);
            deleted++;

            char fileName[PLATFORM_MAX_PATH];
            RV_GetFileName(path, fileName, sizeof(fileName));
            if (strlen(fileName) > RV_REPLAY_SUFFIX_LEN)
            {
                fileName[strlen(fileName) - RV_REPLAY_SUFFIX_LEN] = '\0';
                char metaPath[PLATFORM_MAX_PATH];
                RV_CacheMetaPathOf(fileName, metaPath, sizeof(metaPath));
                if (FileExists(metaPath)) DeleteFile(metaPath);
            }
        }
    }

    delete entries;
    if (deleted > 0)
    {
        LogMessage("[replay-vault] Cache sweep: deleted=%d remainingBytes=%d", deleted, total);
    }
}
