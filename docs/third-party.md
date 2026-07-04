# Third-Party Components

This repository contains deployment glue, configuration templates, and the
`ck3-pruner` and `steamcmd-sidecar` tools maintained in this repository. It
also builds runtime images from external tools.

## Bundled cc-connect Binary

The runtime image includes a bundled `cc-connect` binary at:

```text
dist/cc-connect/linux-amd64/cc-connect
```

Source links:

- Upstream project: <https://github.com/chenhg5/cc-connect>
- Modified branch used by this repository: <https://github.com/Frostbite-time/cc-connect/tree/qq-mention-context>

The upstream project identifies itself as MIT-licensed in its README. This
repository stores only the binary copy needed to build the runtime image; audit
or rebuild that binary from the modified branch above.

## External Tools Used At Build Or Runtime

- Claude Code: installed in the runtime image by `scripts/install-claude-code`.
- SteamCMD: installed in the SteamCMD sidecar image by `scripts/install-steamcmd`.
- onebot-mcp: used as a separate GHCR image, configured by `docker-compose.yml`.

These tools keep their own upstream licenses and release processes. This
repository does not vendor their source code.
