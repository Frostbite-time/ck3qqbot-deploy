# Real Steam Smoke Test

Use this before running a CK3 update. It verifies that SteamCMD can:

- use the persistent `/steam` login cache
- download a real Steam app
- download a real Workshop item
- write reports into `/reports`

The default target is `Ord.`:

- App ID: `1079000`
- Store: <https://store.steampowered.com/app/1079000/Ord/>
- Workshop item: `2339078416` (`Official Story: Quest`)
- Expected scale: current SteamCMD Linux depot installs at a few hundred MiB, and the selected Workshop item is about 91 KiB.

Run after initializing Steam login:

```bash
docker compose run --rm steamcmd-sidecar /usr/local/bin/ck3qqbot-steam-login
docker compose run --rm steamcmd-sidecar /usr/local/bin/ck3qqbot-steam-smoke-download
```

Inspect:

```text
reports/steam-smoke/SUMMARY.txt
reports/steam-smoke/steamcmd.log
reports/steam-smoke/download/game/steamapps/workshop/content/1079000/2339078416
```

Cleanup is safe because the smoke test writes to `reports/steam-smoke/download`
and may also use the SteamCMD workshop cache under
`steamcmd/Steam/steamapps/workshop/content/1079000`.
