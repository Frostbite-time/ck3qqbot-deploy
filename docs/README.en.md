# CK3QQBot Deploy

[中文](../README.md) | English

CK3QQBot Deploy is a quick deployment project for a QQ bot that answers CK3
gameplay and mod-development questions. It uses
[cc-connect](https://github.com/chenhg5/cc-connect) and
[Claude Code](https://code.claude.com/) for the QQ chat runtime, uses SteamCMD
to update the CK3 and Workshop knowledge base, and includes the custom
`ck3-pruner` rule-based pruning tool to reduce disk usage.

This project is not affiliated with the official CK3 team. It is a community
project and does not directly include any CK3 game files; those files are
downloaded by SteamCMD only after deployment.

## Quick Deployment

Before you start, you need at least:

- A QQ service compatible with OneBot v11, such as
  [NapCat](https://github.com/NapNeko/NapCatQQ), LLOneBot, Lagrange.OneBot, or
  another compatible implementation.
- An Anthropic Messages-compatible LLM API with a base URL and an API key.
- A Steam account that can access CK3, used by SteamCMD to download base game
  depots.

The commands below assume you are already in the directory that contains
`docker-compose.yml`.

### 1. Initialize Files

```bash
cp .env.example .env
mkdir -p config runtime knowledge bot-memory bot-tmp onebot-files update-state mcp reports steamcmd steam-downloads
cp config/cc-connect.toml.example config/cc-connect.toml
cp config/claude-settings.json.example config/claude-settings.json
cp config/CLAUDE.md.example config/CLAUDE.md
cp config/.mcp.json.example config/.mcp.json
cp config/prune-rules.json.example config/prune-rules.json
```

On Ubuntu 24.04+ hosts, if runtime needs Claude Code's Bash sandbox, allow
unprivileged user namespaces:

```bash
printf 'kernel.apparmor_restrict_unprivileged_userns = 0\n' | sudo tee /etc/sysctl.d/99-ck3qqbot-claude-userns.conf
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
```

### 2. Edit Required Configuration

At minimum, edit `.env`:

- `CK3QQBOT_ONEBOT_WS_URL`: your OneBot v11 WebSocket address, for example `ws://host.docker.internal:3001`.
- `CK3QQBOT_ONEBOT_TOKEN`: OneBot service token; leave it empty if your service has no token.
- `CK3QQBOT_CLAUDE_PROVIDER_BASE_URL`: Anthropic Messages-compatible API base URL. Claude Code requests `/v1/messages`, so usually do not add an extra `/v1` here.
- `CK3QQBOT_CLAUDE_PROVIDER_API_KEY`: LLM API key.
- `CK3QQBOT_CLAUDE_PROVIDER_MODEL`: model name passed to Claude Code, for example `ops-4.8`.
- `CK3QQBOT_STEAMCMD_MCP_TOKEN`: token used by runtime for the SteamCMD HTTP MCP. Replace the default value.
- `CK3QQBOT_ONEBOT_MCP_TOKEN`: token used by runtime for the OneBot HTTP MCP. Replace the default value.
- `CK3QQBOT_STEAMCMD_INTERNAL_TOKEN`: token used by updater for the SteamCMD sidecar internal API. Replace the default value.
- `CK3QQBOT_STEAM_USER`: Steam username only. Do not put the password or Steam Guard code here.
- `CK3QQBOT_BASE_GAME_DEPOT_IDS`: comma-separated CK3 base-game depots. Leave it empty to skip base-game downloads and update only configured Workshop items.
- `CK3QQBOT_WORKSHOP_MOD_IDS`: optional comma-separated Workshop item IDs. Leave it empty to download only CK3 base game depots.

You will usually also review:

- `config/cc-connect.toml`: QQ permission groups, session policy, group session sharing, and related chat behavior.
- `config/claude-settings.json`: Claude Code permissions, Bash sandbox, and subprocess environment scrubbing. The default uses `dontAsk`, so tool requests not listed in `permissions.allow` are denied.
- `config/CLAUDE.md`: default bot behavior rules and knowledge path instructions.
- `config/prune-rules.json`: pruning rules. For first deployment, keep `CK3QQBOT_PRUNE_DRY_RUN=true` and review reports before deleting files for real.

The default configuration puts real OneBot addresses, OneBot tokens, LLM base
URLs, and API keys in `.env` and passes them into the runtime environment.
Claude Code's default settings scrub these variables from sandboxed Bash
subprocesses. Do not put real addresses or keys directly in `cc-connect.toml` or
`claude-settings.json`; otherwise the bot may leak them.

The default permission policy is strict-deny: `mode = "dontAsk"` in
`cc-connect.toml` rejects tool escalation requests that were not pre-approved,
and `permissions.allow` in `claude-settings.json` defines the allowed scope. To
broaden bot capabilities, update both the allow rules and the sandbox filesystem
rules deliberately.

Runtime briefly starts as root to fix ownership of mounted runtime directories,
then switches to the `node` user before starting cc-connect and Claude Code.
Compose enables `seccomp=unconfined`, `apparmor=unconfined`, and
`systempaths=unconfined` for Claude Code's Bash sandbox.

### 3. Log In to SteamCMD

Log in inside the `steamcmd-sidecar` container so Steam state is persisted in `./steamcmd`:

```bash
docker compose run --rm steamcmd-sidecar /usr/local/bin/ck3qqbot-steam-login
```

Enter the password and Steam Guard code only at the SteamCMD prompt. Do not put
them in `.env`.

Optional: check whether the cached login is usable.

```bash
docker compose run --rm steamcmd-sidecar /usr/local/bin/ck3qqbot-steam-check-login
```

### 4. Start Everything

```bash
docker compose up -d
```

By default this starts:

- `onebot-mcp`: wraps OneBot / NapCat / LLOneBot / Lagrange APIs as HTTP MCP tools.
- `steamcmd-sidecar`: provides the SteamCMD HTTP MCP and the updater's internal download API.
- `runtime`: waits for the knowledge base to become ready, then starts cc-connect/Claude Code.
- `updater-scheduler`: triggers the first knowledge-base update when `update-state/READY` does not exist.

The first CK3 download can take a long time. To inspect first-update progress,
watch the `updater-scheduler` and `runtime` logs.

## Common Project Operations

Refresh the Steam login cache:

```bash
docker compose run --rm steamcmd-sidecar /usr/local/bin/ck3qqbot-steam-login
```

Trigger one manual knowledge-base update:

```bash
docker compose --profile update up -d --force-recreate updater
```

Run the small SteamCMD real-download smoke test:

```bash
docker compose run --rm steamcmd-sidecar /usr/local/bin/ck3qqbot-steam-smoke-download
```

Find pruning reports:

```bash
find reports -name SUMMARY.txt -print
```

Run pruning against the existing knowledge base only, without triggering any
SteamCMD download:

```bash
docker compose run --rm updater ck3-pruner \
  -config /config-input/prune-rules.json \
  -report-dir /reports/manual-prune \
  -root base_game:single:/knowledge/base_game \
  -root workshop_mod:workshop_collection:/knowledge/workshop_mods \
  -dry-run=true
```

After the first report looks correct, set `CK3QQBOT_PRUNE_DRY_RUN=false` in
`.env` to let `ck3-pruner` delete files matched by the pruning rules.

For standalone pruning with real deletion, change `-dry-run=true` to
`-dry-run=false` in the command above. Review the reports under
`reports/manual-prune` first.

## Configure MCP

MCP is managed through project-root `config/.mcp.json` and the mounted `/mcp`
directory. The default `config/.mcp.json.example` enables both the built-in
SteamCMD HTTP MCP and the OneBot HTTP MCP, connecting to `steamcmd-sidecar` and
`onebot-mcp` on the same Compose network. Runtime renders `${VAR}` values that
exist in its environment into `/bot/.mcp.json` at startup; the default Claude
Code permissions deny bot tools from reading that file.

`onebot-mcp` uses the stable GHCR image `ghcr.io/frostbite-time/onebot-mcp:v0.1.2`
by default and is exposed only to runtime through the Compose network, not to a
host port. The default `claude-settings.json` allows common OneBot MCP tools
and explicitly denies high-risk account or group-management tools such as
kicking members, granting admin, deleting friends, and changing group names.
`CK3QQBOT_ONEBOT_MCP_PLATFORM` selects the adapter: `napcat`, `llonebot`, or
`lagrange`.

The default SteamCMD MCP exposes depot, Workshop, task status, and cancellation
tools to the bot. It does not expose full `app_update` downloads. Set
`CK3QQBOT_STEAMCMD_MCP_MAX_DOWNLOAD_KIB` in `.env` to limit the estimated size
of each bot-requested depot or Workshop download; `0` disables the guard. This
is a preflight check only: Workshop uses Steam PublishedFile `file_size`, while
depot downloads use SteamCMD `app_info_print` manifest size metadata. The
internal updater / updater-scheduler API is not limited by this setting. MCP
downloads requested by the bot are written under `steam-downloads/` and are
mounted read-write inside runtime at `/bot/steam-downloads` so the bot can clean
up temporary downloads it no longer needs.

Custom MCP servers can still live under `/mcp`. Recommended layout:

```text
mcp/<server>/bin/...       MCP executable or launcher script
mcp/<server>/config.toml   MCP-specific config
mcp/<server>/data/...      MCP-specific data
```

Copy the example first:

```bash
cp config/.mcp.json.example config/.mcp.json
```

Then add servers in `config/.mcp.json`:

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

See [mcp.md](mcp.md) for more details.

## Project Layout

```text
config/                 Default config templates
dist/cc-connect/        cc-connect binary used by this project
docs/                   Runtime contracts and detail docs
scripts/                Container entrypoints, SteamCMD, and update scripts
tools/ck3-pruner/       Rust knowledge-base pruning tool
tools/steamcmd-sidecar/ TypeScript SteamCMD HTTP MCP sidecar
docker-compose.yml      Compose service definition
.env.example            Environment variable template
```

Default mounted directories:

```text
config/       -> /config-input    Config input
runtime/      -> /runtime         Runtime state and generated config
knowledge/    -> /knowledge       Knowledge base written by updater
knowledge/    -> /bot/knowledge   Read-only knowledge base in runtime
bot-memory/   -> /bot/bot-memory  Long-term bot memory
bot-tmp/      -> /bot/bot-tmp     Bot temporary directory
onebot-files/ -> /bot/onebot-files OneBot upload staging directory shared by runtime and onebot-mcp
update-state/ -> /update-state    READY, .updating, and update state files
mcp/          -> /mcp             User-provided MCP servers
reports/      -> /reports         Update and pruning reports
steamcmd/     -> /steam           SteamCMD login cache and download state
steam-downloads/ -> /downloads, /bot/steam-downloads    Temporary SteamCMD MCP downloads
```

`onebot-files/` is the only default upload staging directory shared by runtime
and `onebot-mcp`. If the bot needs to upload a file through OneBot MCP, it should
first copy a temporary copy to `/bot/onebot-files` and pass that path to the
upload tool. Do not upload files directly from the knowledge base, config,
logs, memory, hidden files, or runtime directories.

## cc-connect Binary

The runtime image includes a personally modified `cc-connect` binary:

```text
dist/cc-connect/linux-amd64/cc-connect
```

The `cc-connect` binary used by this project includes a small set of changes on
top of the original project:

- When `group_reply_all = false`, group chats trigger the bot only after an @ mention, so ordinary group messages do not all enter the bot.
- Mention-triggered messages can include recent group context, with a configurable character limit.
- OneBot `reply` segments can be resolved through `get_msg` and injected as quoted-message context.
- The mention-gated group-message path is fixed so @ mentions are not incorrectly blocked.
- Agent profile switching and compaction continuation output suppression are included for this deployment workflow.

Code links:

- Upstream project: [chenhg5/cc-connect](https://github.com/chenhg5/cc-connect)
- Modified branch used here: [Frostbite-time/cc-connect/tree/qq-mention-context](https://github.com/Frostbite-time/cc-connect/tree/qq-mention-context)

See [third-party.md](third-party.md) for bundled binary and external component
notes.

## Acknowledgements

This project uses or integrates:

- [cc-connect](https://github.com/chenhg5/cc-connect)
- [Claude Code](https://code.claude.com/)
- [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD)

## License

This project is released under the MIT License. The bundled `ck3-pruner` pruning
tool is also released under the MIT License.
