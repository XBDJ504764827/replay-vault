# PR: develop → main

> 仅允许 `develop → main`。合并前 `pr-check` 必须通过（`STRICT=1` 零警告 + 单一 `smx` 校验），`Artifacts` 中 `replay-vault-pr{N}.zip` 为测试包。

## 变更类型

- [ ] 功能（`minor`）
- [ ] 修复（`patch`）
- [ ] 不兼容（`major`）

## 版本

- [ ] 已在 `addons/sourcemod/scripting/include/replay-vault/version.inc` 按 `semver` 自增（`Release` 以此打 `tag`，未自增会导致 `release.yml` 失败）
- 当前 `REPLAY_VAULT_VERSION`: `x.y.z` → `x.y.z`

## Code Review 清单

- [ ] 无阻塞主线程的同步 I/O（仅允许 `staging` 复制的短同步，禁止 `HTTP` 同步）
- [ ] 空句柄/无效 `client` / 缺失文件均有防护（`IsValidClient` / `FileExists` / `GetClientAuthId` 失败回退）
- [ ] `GOKZ_RP_OnReplaySaved` 永远 `return Plugin_Continue`，不干扰 `GOKZ` 本地保存
- [ ] `tempReplay`（`_tempRuns`）与 `course` 边界正确（`runs` 全量含 `temp`，`course`→`main/b1...`）
- [ ] 键名符合 `docs/DEVELOPMENT.md §2.2`（小写、日期 `yyyy.MM.dd.HH.mm.ss`、地图置顶、不含 `style`）
- [ ] `UUIDv4` 且 `X-UUID` 正确传递，`staging` 文件名带 `UUID`
- [ ] 聊天回显仅对完成者本人且仅 `runs`（`jumps/cheaters` 仅日志，除非 `replay_vault_announce_jumps=1`）
- [ ] `STRICT=1 ./build.sh` 零警告，产物仅 `1` 个 `replay-vault.smx`

## 测试

- [ ] 已下载 `Artifacts` 测试包在测试服验证
- [ ] 完成录像（未破 PB / Bonus / NUB/PRO）均在 `R2` 出现 `{map}/runs/.../{date}_{uuid}.replay`，聊天回显 `UUID`
- [ ] 跳远 / 作弊录像按 `2.2` 键模板出现在 `R2`
- [ ] `replay_vault_url/key` 为空时不上传且无刷屏
- [ ] 删除 `cfg/sourcemod/replay-vault.cfg` 重启后重建，已有配置不丢失

## 备注

<!-- 重大改动说明、Worker/D1 变更、回滚要点等 -->
