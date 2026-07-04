# Deployment Paths

The Compose file uses simple host-side directories by default. They are operational paths, not a generated application layout.

```text
./config      -> /config-input  read-only config input
./runtime     -> /runtime       runtime writable state
./runtime/cc-connect            cc-connect data_dir: sessions, cron jobs, and local state
./knowledge   -> /knowledge     updater-owned CK3 and Workshop knowledge
./knowledge   -> /bot/knowledge read-only bot-facing knowledge path
./bot-memory  -> /bot/bot-memory writable bot long-term public memory
./bot-tmp     -> /bot/bot-tmp    writable bot temporary workspace
./onebot-files -> /bot/onebot-files writable OneBot upload staging shared by runtime and onebot-mcp
./update-state -> /update-state  updater/runtime markers and READY state
./mcp         -> /mcp           user-owned MCP config/data
./reports     -> /reports       update and prune reports
./steamcmd    -> /steam         SteamCMD cache and login state
./steam-downloads -> /downloads, /bot/steam-downloads temporary SteamCMD MCP downloads
```

`/config-input` is never the final active config path. Runtime startup copies
user config files into:

```text
/runtime/config/cc-connect.toml
/runtime/cc-connect
/runtime/claude-home/settings.json
/bot/CLAUDE.md
/bot/.mcp.json
/bot/knowledge
/bot/bot-memory
/bot/bot-tmp
/bot/onebot-files
```

Claude Code and MCP config should use container paths. For example, a Claude
Code MCP server can point at `/mcp/llbot/config.toml`; the host can later move
`./mcp` by changing `.env` without editing that MCP config. Bot-facing
instructions should use paths relative to `/bot`, such as
`knowledge/base_game/game/common`, `knowledge/workshop_mods`, `bot-memory`, and
`bot-tmp`. Files uploaded through OneBot MCP must be staged under
`onebot-files` first; this is the only default read-write directory shared
between runtime and `onebot-mcp`.

The default provider endpoint is injected through `cc-connect` provider
environment variables. Real provider URL/key and OneBot URL/token stay in
`.env`; Claude Code settings scrub them from sandboxed Bash subprocesses.

Runtime starts through a small root entrypoint that fixes ownership of writable
mount points and then execs the runtime as the `node` user. Claude Code's Bash
sandbox uses weaker nested sandbox mode by default and requires the runtime
service `security_opt` entries in `docker-compose.yml`. Ubuntu 24.04+ hosts
also need `kernel.apparmor_restrict_unprivileged_userns = 0` for this non-root
container path.

`steamcmd-sidecar` owns the persistent SteamCMD cache at `/steam`. It can write
to `/knowledge` only through updater's internal API token, and it exposes a
separate runtime MCP token for downloads under `/downloads`. Runtime mounts
`/knowledge` read-only and keeps internal services stopped while
`/update-state/.updating` exists or `/update-state/READY` is missing. Runtime
only writes update handshake state under `/update-state`.
