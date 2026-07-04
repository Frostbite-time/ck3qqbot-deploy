# CK3QQBot Deploy

中文 | [English](docs/README.en.md)

CK3QQBot Deploy 用于快速部署一个面向 CK3 游戏和 Mod 开发问题的 QQ
机器人。它基于 [cc-connect](https://github.com/chenhg5/cc-connect) 和
[Claude Code](https://code.claude.com/) 提供 QQ 对话能力，通过
SteamCMD 自动更新 CK3/创意工坊知识库，并提供自定义规则裁剪工具
`ck3-pruner` 来降低硬盘占用。

本项目与 CK3 官方无任何关系，仅为社区项目。项目内容也不直接包含任何 CK3
游戏文件；相关文件仅在部署后通过 SteamCMD 下载。

## 快速部署

开始前至少需要准备：

- 一个支持 OneBot v11 的 QQ 服务，例如
  [NapCat](https://github.com/NapNeko/NapCatQQ)、LLOneBot、Lagrange.OneBot
  或其他兼容实现。
- 一个 Anthropic Messages 兼容的 LLM API，至少需要 base URL 形式的接口地址和 API key。
- 一个可登录 CK3 的 Steam 账号，用于 SteamCMD 下载基础游戏 depot。

以下命令假设你已经进入包含 `docker-compose.yml` 的项目目录。

### 1. 初始化文件

```bash
cp .env.example .env
mkdir -p config runtime knowledge bot-memory bot-tmp onebot-files update-state mcp reports steamcmd steam-downloads
cp config/cc-connect.toml.example config/cc-connect.toml
cp config/claude-settings.json.example config/claude-settings.json
cp config/CLAUDE.md.example config/CLAUDE.md
cp config/.mcp.json.example config/.mcp.json
cp config/prune-rules.json.example config/prune-rules.json
```

如果宿主是 Ubuntu 24.04+，并且 runtime 需要使用 Claude Code 的 Bash sandbox，
需要允许非特权 user namespace：

```bash
printf 'kernel.apparmor_restrict_unprivileged_userns = 0\n' | sudo tee /etc/sysctl.d/99-ck3qqbot-claude-userns.conf
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
```

### 2. 编辑必要配置

最少需要编辑 `.env`：

- `CK3QQBOT_ONEBOT_WS_URL`：OneBot v11 WebSocket 地址，例如 `ws://host.docker.internal:3001`。
- `CK3QQBOT_ONEBOT_TOKEN`：OneBot 服务 token；没有 token 可留空。
- `CK3QQBOT_CLAUDE_PROVIDER_BASE_URL`：Anthropic Messages 兼容 API base URL。Claude Code 会请求 `/v1/messages`，通常不要在这里额外加 `/v1`。
- `CK3QQBOT_CLAUDE_PROVIDER_API_KEY`：LLM API key。
- `CK3QQBOT_CLAUDE_PROVIDER_MODEL`：传给 Claude Code 的模型名，例如 `ops-4.8`。
- `CK3QQBOT_STEAMCMD_MCP_TOKEN`：runtime 调用 SteamCMD HTTP MCP 的 token，请替换默认值。
- `CK3QQBOT_ONEBOT_MCP_TOKEN`：runtime 调用 OneBot HTTP MCP 的 token，请替换默认值。
- `CK3QQBOT_STEAMCMD_INTERNAL_TOKEN`：updater 调用 SteamCMD sidecar 内部 API 的 token，请替换默认值。
- `CK3QQBOT_STEAM_USER`：Steam 用户名，只写用户名，不写密码和 Steam Guard。
- `CK3QQBOT_BASE_GAME_DEPOT_IDS`：逗号分隔的 CK3 基础游戏 depot；留空则不下载基础游戏，只更新配置的创意工坊项目。
- `CK3QQBOT_WORKSHOP_MOD_IDS`：可选，逗号分隔的创意工坊项目 ID；留空则只下载 CK3 基础游戏 depot。

通常还会检查：

- `config/cc-connect.toml`：QQ 权限组、会话策略、是否群聊共享上下文等。
- `config/claude-settings.json`：Claude Code 权限、Bash sandbox、子进程环境变量清理等。默认使用 `dontAsk`，未写入 `permissions.allow` 的工具请求会被拒绝。
- `config/CLAUDE.md`：机器人默认行为规则和知识库路径说明。
- `config/prune-rules.json`：裁剪规则。首次部署建议保持 `CK3QQBOT_PRUNE_DRY_RUN=true`，先看报告再真的删除。

默认配置会把真实 OneBot 地址、OneBot token、LLM base URL 和 API key 放在 `.env`
并作为 runtime 环境变量传入。Claude Code 的默认配置会把这些变量从 sandboxed
Bash 子进程中清理掉。
不要把真实地址和 key 直接写进 `cc-connect.toml` 或 `claude-settings.json`，否则 bot
可能会泄露它们。

默认权限是严格拒绝模式：`cc-connect.toml` 中的 `mode = "dontAsk"` 会拒绝所有
未预批准的工具提权请求，`claude-settings.json` 中的 `permissions.allow`
定义允许范围。如需扩大机器人能力，请先修改 allow 规则和 sandbox 文件系统规则。

Runtime 默认短暂以 root 进入容器修正挂载目录权限，然后切换为 `node`
用户运行 cc-connect 和 Claude Code。Compose 同时为 Claude Code Bash sandbox
开启 `seccomp=unconfined`、`apparmor=unconfined` 和 `systempaths=unconfined`。

### 3. 登录 SteamCMD

先在 `steamcmd-sidecar` 容器里完成 Steam 登录，让登录状态保存在 `./steamcmd`：

```bash
docker compose run --rm steamcmd-sidecar /usr/local/bin/ck3qqbot-steam-login
```

密码和 Steam Guard 只在 SteamCMD 交互提示里输入，不要写进 `.env`。

可选：检查缓存登录是否可用。

```bash
docker compose run --rm steamcmd-sidecar /usr/local/bin/ck3qqbot-steam-check-login
```

### 4. 一行启动

```bash
docker compose up -d
```

默认会启动：

- `onebot-mcp`：把 OneBot / NapCat / LLOneBot / Lagrange API 封装成 HTTP MCP。
- `steamcmd-sidecar`：提供 SteamCMD HTTP MCP 和 updater 内部下载 API。
- `runtime`：等待知识库 ready，ready 后启动 cc-connect/Claude Code。
- `updater-scheduler`：如果还没有 `update-state/READY`，会触发首次知识库更新。

首次 CK3 下载可能很久。需要观察首次更新时，可以看 `updater-scheduler` 和
`runtime` 日志。

## 常用项目操作

刷新 Steam 登录缓存：

```bash
docker compose run --rm steamcmd-sidecar /usr/local/bin/ck3qqbot-steam-login
```

手动触发一次知识库更新：

```bash
docker compose --profile update up -d --force-recreate updater
```

运行小体积 SteamCMD 真实下载测试：

```bash
docker compose run --rm steamcmd-sidecar /usr/local/bin/ck3qqbot-steam-smoke-download
```

查看裁剪报告：

```bash
find reports -name SUMMARY.txt -print
```

只对已有知识库单独运行裁剪，不触发 SteamCMD 下载：

```bash
docker compose run --rm updater ck3-pruner \
  -config /config-input/prune-rules.json \
  -report-dir /reports/manual-prune \
  -root base_game:single:/knowledge/base_game \
  -root workshop_mod:workshop_collection:/knowledge/workshop_mods \
  -dry-run=true
```

如果首次报告确认无误，再把 `.env` 中的 `CK3QQBOT_PRUNE_DRY_RUN=false` 打开，
让 `ck3-pruner` 真正删除被规则裁掉的文件。

单独裁剪时如果也要实际删除，把上面命令里的 `-dry-run=true` 改成
`-dry-run=false`。建议先检查 `reports/manual-prune` 里的报告。

## 配置 MCP

MCP 配置由项目根目录的 `config/.mcp.json` 和 `/mcp` 挂载目录共同管理。默认
`config/.mcp.json.example` 已启用内置 SteamCMD HTTP MCP 和 OneBot HTTP MCP，
分别连接到同一个 Compose 网络里的 `steamcmd-sidecar` 与 `onebot-mcp`。
runtime 启动时会把其中已有环境变量的 `${VAR}` 渲染到 `/bot/.mcp.json`；默认
Claude Code 权限禁止 bot 工具读取这个文件。

`onebot-mcp` 默认使用稳定 GHCR 镜像 `ghcr.io/frostbite-time/onebot-mcp:v0.1.2`，
只通过 Compose 内部网络暴露给 runtime，不发布到宿主机端口。默认
`claude-settings.json` 开放常用 OneBot MCP 工具，同时显式禁用踢人、设管理员、
删好友、改群名等高风险账号或群管理工具。`CK3QQBOT_ONEBOT_MCP_PLATFORM`
控制平台适配器，可选 `napcat`、`llonebot`、`lagrange`。

默认 SteamCMD MCP 只给 bot 暴露 depot、Workshop、任务查询和取消能力，不暴露
完整 `app_update` 下载工具。可以通过 `.env` 的
`CK3QQBOT_STEAMCMD_MCP_MAX_DOWNLOAD_KIB` 限制 bot 发起的单个 depot /
Workshop 下载预估大小；`0` 表示不限制。这个限制只做下载前预检，Workshop 使用
Steam PublishedFile `file_size`，depot 使用 SteamCMD `app_info_print` 里的
manifest size metadata。updater / updater-scheduler 使用的内部更新 API 不受此
限制。bot 发起的 MCP 下载实际写入 `steam-downloads/`，runtime 里以
`/bot/steam-downloads` 读写，用于让 bot 清理不再需要的临时下载文件。

用户自定义 MCP 可以继续放在 `/mcp`，推荐目录约定：

```text
mcp/<server>/bin/...       MCP 可执行文件或启动脚本
mcp/<server>/config.toml   MCP 自己的配置
mcp/<server>/data/...      MCP 自己的数据
```

先复制示例文件：

```bash
cp config/.mcp.json.example config/.mcp.json
```

然后在 `config/.mcp.json` 中添加：

```json
{
  "mcpServers": {
    "llbot": {
      "command": "/mcp/llbot/bin/llbot-mcp",
      "args": [],
      "env": {
        "LLBOT_MCP_CONFIG": "/mcp/llbot/config.toml",
        "RUST_LOG": "info"
      }
    }
  }
}
```

更完整的说明见 [docs/mcp.md](docs/mcp.md)。

## 项目结构

```text
config/                 默认配置模板
dist/cc-connect/        项目使用的 cc-connect 二进制
docs/                   运行契约和细节文档
scripts/                容器入口、SteamCMD、更新脚本
tools/ck3-pruner/       Rust 编写的知识库裁剪工具
tools/steamcmd-sidecar/ TypeScript 编写的 SteamCMD HTTP MCP sidecar
docker-compose.yml      Compose 服务定义
.env.example            环境变量模板
```

默认挂载目录：

```text
config/       -> /config-input    配置输入
runtime/      -> /runtime         runtime 状态和生成配置
knowledge/    -> /knowledge       updater 写入的知识库
knowledge/    -> /bot/knowledge   runtime 只读知识库
bot-memory/   -> /bot/bot-memory  机器人长期记忆
bot-tmp/      -> /bot/bot-tmp     机器人临时目录
onebot-files/ -> /bot/onebot-files runtime 与 onebot-mcp 共享的 OneBot 上传暂存目录
update-state/ -> /update-state    READY、.updating 等更新状态
mcp/          -> /mcp             用户自定义 MCP
reports/      -> /reports         更新和裁剪报告
steamcmd/     -> /steam           SteamCMD 登录缓存和下载状态
steam-downloads/ -> /downloads, /bot/steam-downloads    SteamCMD MCP 临时下载目录
```

`onebot-files/` 是 runtime 和 `onebot-mcp` 之间唯一默认共享的上传暂存目录。
如果 bot 需要通过 OneBot MCP 上传文件，应先把要上传的文件临时复制到
`/bot/onebot-files`，再把该路径传给上传工具。不要直接上传知识库、配置、日志、
记忆、隐藏文件或运行时目录里的文件。

群文件上传最终由 OneBot 后端进程读取本地文件，因此 runtime、`onebot-mcp` 和
实际 OneBot 后端（例如 NapCat、LLOneBot、Lagrange.OneBot 或 llbot）必须至少有
一个共同挂载目录，并且传给上传工具的路径必须是 OneBot 后端容器也能看到的路径。
如果 OneBot 后端本身拆成多个容器或进程，必须确保真正执行文件传输的那个容器或
进程也能看到同一路径；例如 llbot 的文件上传最终会经过 PMHQ/NTQQ 侧处理，因此
llbot 与 PMHQ 都需要挂载同一个上传目录。
如果只让 runtime 与 `onebot-mcp` 共享目录，而 OneBot 后端没有相同挂载，
`upload_group_file` 会在后端报“路径不存在”或类似错误。群文件下载工具通常返回
URL 或文件元数据，不需要额外共享目录。

## cc-connect 二进制

本项目随 runtime 镜像放入一个个人修改版 `cc-connect` 二进制：

```text
dist/cc-connect/linux-amd64/cc-connect
```

本项目使用的 `cc-connect` 在原项目基础上做了少量修改，主要包括：

- `group_reply_all = false` 时，群聊只在 @ 机器人后触发，避免普通群消息全部进入机器人。
- @ 触发时可注入最近群聊上下文，并可限制上下文字数。
- 支持解析 OneBot `reply` 引用段，通过 `get_msg` 获取被引用消息并注入引用上下文。
- 修复 mention-gated 群消息处理路径，避免 @ 触发被错误拦截。
- 增加 agent profile 切换和压缩续写输出抑制等对部署体验有用的行为。

代码地址：

- 上游项目：[chenhg5/cc-connect](https://github.com/chenhg5/cc-connect)
- 本项目使用的修改分支：[Frostbite-time/cc-connect/tree/qq-mention-context](https://github.com/Frostbite-time/cc-connect/tree/qq-mention-context)

第三方二进制和外部组件说明见 [docs/third-party.md](docs/third-party.md)。

## 致谢

本项目使用或集成了以下工具：

- [cc-connect](https://github.com/chenhg5/cc-connect)
- [Claude Code](https://code.claude.com/)
- [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD)

## License

本项目基于 MIT 协议发布。项目内的 `ck3-pruner` 裁剪工具同样基于 MIT 协议。
