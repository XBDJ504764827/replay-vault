# replay-vault

CS:GO GOKZ 落盘录像备份插件 — `gokz-replays` 只要落盘（完成：破纪录 + 破 PB 未破纪录，含 Bonus/NUB-PRO；跳远/作弊）就异步上传到 Cloudflare R2（Worker 中转），按 `UUID` 命名，比 PB 慢的不落盘不上传，完成即在聊天框回显 `UUID` 供玩家按 `UUID` 检索下载，R2 侧 3 天自动删除。

> 与 `stratosphere` 区分：`stratosphere` 仅备份 `WR`（`wr/{mode}/{map}/{tp|pro}.replay` 最快者胜覆盖），`replay-vault` 是**落盘即备份**（`{map}/runs|jumps|cheaters/.../{date}_{uuid}.replay` 每份独立，3 天生命周期）。

## 特性

- 📦 **落盘即上传**：完成录像（破纪录 + 破 PB 未破纪录，含 Bonus/NUB-PRO，比 PB 慢的不落盘不上传）+ 跳远/作弊录像，只要落盘就上传，零改上游
- 🗺️ **地图置顶键名**：`kz_map/runs/main/{steamid64}/kzt/pro/{date}_{uuid}.replay`，便于按图/人前缀查询
- 🔑 **UUID 命名**：插件端 `UUIDv4` 生成，`X-UUID` 传 Worker，文件名为 `年.月.日.时.分.秒_uuid.replay`（北京时间，点分隔）
- 💬 **聊天回显**：完成录像上传成功后向完成者回显 `录像已上传 UUID: xxxxxxxx-...`
- 🛡️ **竞态防护**：上传前同步复制到 `data/replay-vault/staging/{uuid}.replay`，源文件被 `gokz-global` 删除不影响
- 🔐 **Worker 中转**：`SteamWorks` + `X-API-Key` + 可选 `X-SHA256`，不在 `Pawn` 层做 `R2` 签名
- 🧱 **单一 SMX**：`replay-vault.sp` + `replay-vault/` 模块目录，仅产出一个 `replay-vault.smx`
- ⏰ **3 天生命周期**：R2 `Lifecycle Expiration 3 days` + D1 每日 Cron 清理过期 `uuid→key`，到期自动删除
- 🔇 **纯后台**：无命令、无菜单

## 键名约定

```text
{map}/runs/{course}/{steamid64}/{mode}/{timetype}/{date}_{uuid}.replay
{map}/jumps/{steamid64}/{mode}/{jumpType}/{date}_{uuid}.replay
{map}/jumps/{steamid64}/{mode}/{jumpType}/block_{block}/{date}_{uuid}.replay
{map}/cheaters/{steamid64}/{mode}/{reason}/{date}_{uuid}.replay

# course: 0→main, 1→b1, 2→b2 ...   mode: kzt/skz/vnl   timetype: pro/nub
# date: 年.月.日.时.分.秒  北京时间  例 2025.08.24.14.30.45
# 示例：
kz_bhop_league/runs/main/76561198123456789/kzt/pro/2025.08.24.14.30.45_a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5.replay
```

不含 `style`（当前 `STYLE_COUNT==1` 仅 `Normal`，为简洁省略；未来若新增风格再在 `mode` 后追加层，详见 `docs/DEVELOPMENT.md §2`）。

## 目录结构

```
addons/sourcemod/scripting/replay-vault.sp        # 唯一入口
addons/sourcemod/scripting/replay-vault/           # 模块目录
addons/sourcemod/scripting/include/replay-vault/   # version.inc
addons/sourcemod/translations/                     # replay-vault.phrases.txt
cfg/sourcemod/replay-vault.cfg                     # 运行时幂等生成（已存在不覆盖）
docs/DEVELOPMENT.md                                # 开发文档（唯一依据）
build.sh                                           # 编译脚本
.github/workflows/pr-check.yml                     # PR: develop→main 编译审查 + 测试包
.github/workflows/release.yml                      # push main → Release
```

## 编译

```sh
./build.sh setup   # 首次：下载 SourceMod 1.11 + GOKZ includes 到 .sm111/ .deps/
./build.sh         # 编译 → addons/sourcemod/plugins/replay-vault.smx
STRICT=1 ./build.sh  # 警告即错误（CI 用）
```

## 安装

1. 下载 `Releases` 中 `replay-vault-vX.Y.Z.zip`（或 `PR` 测试包 `replay-vault-pr{N}.zip`）。
2. 将 `addons/` 合并进服务器根目录。Release 包不包含配置文件，避免覆盖服务器现有配置。
3. 首次启动插件会自动生成 `cfg/sourcemod/replay-vault.cfg`；在该文件中填入 `replay_vault_url`（新 Worker 地址）与 `replay_vault_key`。
4. 重启或 `sm plugins load replay-vault`。

> 配置文件首次启动自动创建，已存在不覆盖，仅补齐新增 `ConVar`。后续更新 Release 包不会覆盖服务器配置。

## 依赖

- SourceMod 1.11（`spcomp64`）
- SteamWorks 扩展
- GOKZ + gokz-replays
- Cloudflare Worker（新建 `replay-vault` Worker，协议见 `docs/DEVELOPMENT.md §3`）

## 开发

详见 `docs/DEVELOPMENT.md`。

- 分支：`develop` 日常开发 → `PR develop→main` 触发 `pr-check`（`STRICT=1` 编译 + 测试包供下载）→ 合并后 `push main` 触发 `release` 打 `Release`。
- 版本：`addons/sourcemod/scripting/include/replay-vault/version.inc` 按 `semver` 自增，初始 `v0.1.0`。

## 许可证

同 GOKZ 生态，见仓库 `LICENSE`。
