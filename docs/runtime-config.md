# Runtime Config

The runtime container treats external config as a read-only input.

The runtime entrypoint briefly runs as root to create/chown writable mount
points, then starts the runtime process as the image's `node` user. This keeps
cc-connect, Claude Code, and sandboxed Bash out of root while still allowing
fresh host directories created by `mkdir -p` to work on first boot.

It does not directly run against `/config-input`, because tools such as `cc-connect` can write lock files or persist small config changes next to their active config. Startup copies the user-provided files into writable internal paths and then starts `cc-connect`.

Required inputs:

```text
/config-input/cc-connect.toml
/config-input/claude-settings.json
/config-input/CLAUDE.md
```

Optional input:

```text
/config-input/project-claude-settings.json
/config-input/.claude/settings.json
/config-input/.mcp.json
```

Outputs:

```text
/runtime/config/cc-connect.toml
/runtime/cc-connect
/runtime/claude-home/settings.json
/bot/CLAUDE.md
/bot/.claude/settings.json
/bot/.mcp.json
/bot/knowledge
/bot/bot-memory
/bot/bot-tmp
/bot/onebot-files
```

Provider placeholders are intentionally resolved by `cc-connect` from runtime
environment variables. The default deployment keeps real provider addresses and
keys out of `cc-connect.toml` and Claude settings, then relies on Claude Code
sandbox credential rules to scrub those variables from sandboxed Bash
subprocesses.

Project MCP config is the exception: startup renders available `${VAR}`
placeholders from `/config-input/.mcp.json` into `/bot/.mcp.json` so Claude Code
can connect to HTTP MCP endpoints such as `steamcmd-sidecar`; unresolved
placeholders are left unchanged. Default permission and sandbox rules deny bot
tools from reading `/bot/.mcp.json`.

The default `cc-connect` config sets `data_dir = "/runtime/cc-connect"`.
With the default `CK3QQBOT_RUNTIME_STATE=./runtime` mount, cc-connect sessions,
cron jobs, and local runtime state are persisted on the host under
`./runtime/cc-connect`.

The knowledge tree is also mounted read-only at `/bot/knowledge` so the default
bot workdir can refer to it with relative paths such as
`knowledge/base_game/game/common` and `knowledge/workshop_mods`. Bot writable
state is split into `/bot/bot-memory` for long-term public memory and
`/bot/bot-tmp` for temporary task files. Files that need to be uploaded through
OneBot MCP must be copied into `/bot/onebot-files` first, because that path is
shared read-write with the `onebot-mcp` container.

`ck3qqbot-doctor` fails closed while `/update-state/.updating` exists or `/update-state/READY` is missing. In the default watchdog startup mode, the runtime container does not exit on missing `READY`; it keeps internal services stopped, watches update state, and starts services once `READY` exists. `CK3QQBOT_FORCE_START=true` bypasses the doctor check for manual recovery only.
