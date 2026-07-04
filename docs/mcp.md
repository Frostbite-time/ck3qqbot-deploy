# MCP Contract

MCP configuration is intentionally owned by project-root `.mcp.json` and the
`/mcp` volume.

The default `config/.mcp.json.example` enables the built-in SteamCMD HTTP MCP
and the OneBot HTTP MCP:

```json
{
  "mcpServers": {
    "steamcmd": {
      "type": "http",
      "url": "http://steamcmd-sidecar:${CK3QQBOT_STEAMCMD_MCP_PORT}/mcp",
      "headers": {
        "Authorization": "Bearer ${CK3QQBOT_STEAMCMD_MCP_TOKEN}"
      },
      "alwaysLoad": true
    },
    "onebot": {
      "type": "http",
      "url": "http://onebot-mcp:${CK3QQBOT_ONEBOT_MCP_PORT}/mcp",
      "headers": {
        "Authorization": "Bearer ${CK3QQBOT_ONEBOT_MCP_TOKEN}"
      },
      "alwaysLoad": true
    }
  }
}
```

Runtime renders available `${VAR}` placeholders in `config/.mcp.json` into
`/bot/.mcp.json` before Claude Code starts. Unresolved placeholders are left
unchanged. This lets the MCP client receive the Compose-configured port and
token while the default Claude Code permission and sandbox rules deny bot tools
from reading `/bot/.mcp.json`.

The OneBot MCP endpoint runs in the separate `onebot-mcp` service and uses the
stable GHCR image `ghcr.io/frostbite-time/onebot-mcp:v0.1.2` by default. It is
not published to the Docker host; runtime reaches it through the Compose DNS
name `onebot-mcp`. `CK3QQBOT_ONEBOT_MCP_PLATFORM` selects the OneBot adapter:
`napcat`, `llonebot`, or `lagrange`. The default Claude Code settings allow
common OneBot MCP tools and explicitly deny high-risk account or group
management tools, including kicking members, granting admin, deleting friends,
and changing group names.

Runtime and `onebot-mcp` share one read-write upload staging directory:
`CK3QQBOT_ONEBOT_FILES` on the host, mounted as `/bot/onebot-files` in both
containers. Files uploaded through OneBot MCP should be copied there first and
uploaded from that path. The default Claude prompt and permissions treat other
bot directories as non-upload sources.

That MCP endpoint runs in `steamcmd-sidecar`, not in runtime. Runtime receives
only `CK3QQBOT_STEAMCMD_MCP_TOKEN`; updater containers receive the separate
`CK3QQBOT_STEAMCMD_INTERNAL_TOKEN` for update-only APIs. The runtime-facing MCP
tools can queue Steam depot/Workshop downloads under `/downloads`, query task
status, and cancel tasks without exposing raw SteamCMD logs. Full `app_update`
downloads are intentionally not exposed to the bot-facing MCP because they can
pull uncontrolled extra content.

The sidecar writes bot-requested MCP downloads to its `/downloads` volume. The
same host directory is mounted read-write into runtime at `/bot/steam-downloads`,
and MCP task responses include `runtimeTargetDir` so the bot can inspect and
clean completed temporary downloads without touching `/knowledge`.

`CK3QQBOT_STEAMCMD_MCP_MAX_DOWNLOAD_KIB` limits the estimated size of each
bot-facing MCP depot or Workshop download when set to a value greater than `0`.
The guard runs before queuing the SteamCMD task:

- Workshop preflight calls Steam PublishedFile details and checks `file_size`.
- Depot preflight runs SteamCMD `app_info_print` and checks depot manifest size
  metadata.
- If the size cannot be determined while the guard is enabled, the request is
  rejected instead of starting a download.
- The guard does not kill an already-running SteamCMD task; it is preflight
  only.
- Internal updater endpoints are not limited by this setting.

Default convention:

```text
/mcp/<server>/bin/...       executable files or launch scripts
/mcp/<server>/config.toml   server-specific config
/mcp/<server>/data/...      optional server state/data
```

Example additional stdio MCP in Claude Code `.mcp.json`:

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

This deployment does not expand every MCP server into a second deployment config
format. If a server needs private config, keep it below `/mcp/<server>` and use
Claude Code permission rules and sandbox credentials to deny tool access to
those files where needed.

If an MCP requires system packages or shared libraries that are not present in the runtime image, either provide a self-contained binary under `/mcp` or extend `Dockerfile.runtime` for that deployment.
