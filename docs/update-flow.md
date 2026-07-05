# Update Flow

The updater owns the `/knowledge` update workflow. SteamCMD itself runs in
`steamcmd-sidecar`; updater calls the sidecar's internal API with
`CK3QQBOT_STEAMCMD_INTERNAL_TOKEN`, waits for each task, then runs pruning.
Runtime treats `/knowledge` as read-only and only has the runtime MCP token,
which is limited to `/downloads`.

State files:

- `/update-state/.update-lock`: updater entry lock used to serialize one-shot and scheduled update attempts.
- `/update-state/.updating`: update is in progress or failed before cleanup.
- `/update-state/.runtime-confirm`: runtime has stopped internal services for the current update.
- `/update-state/READY`: last successful update completed.
- `/update-state/FAILED`: metadata copied from the failed update marker when an update fails after `.updating` is written.
- `/knowledge/SUMMARY.txt`: human-readable update summary.
- `/knowledge/MANIFEST.txt`: generated inventory for the current knowledge tree.

Runtime startup must fail closed when `.updating` exists unless an explicit force-start mode is used.

Pruning is in-place to avoid doubling peak disk usage. The pruning tool therefore plans deletions first, checks the delete ratio guard, writes reports, then deletes files unless `DryRun` is enabled.

## Capacity And Login

The updater checks free space before submitting SteamCMD sidecar tasks when
`CK3QQBOT_MIN_FREE_KIB` is non-zero. It prunes after each configured base-game
depot and after each Workshop item, instead of waiting for the whole update
batch to complete.

If `CK3QQBOT_CLEAN_BEFORE_UPDATE=true`, the updater removes managed knowledge
directories after runtime confirms shutdown and before SteamCMD sidecar downloads new
files. When `CK3QQBOT_BASE_GAME_DEPOT_IDS` is non-empty, it removes
`/knowledge/base_game`. It also removes `/knowledge/workshop_mods`, so the configured
`CK3QQBOT_WORKSHOP_MOD_IDS` becomes the full desired Workshop set. This cleanup
is destructive and is independent of `CK3QQBOT_PRUNE_DRY_RUN`.

Base game updates use `download_depot`, not `app_update`. `app_update` can
process Workshop state for the logged-in Steam account and may pull subscribed
items that are not listed in `CK3QQBOT_WORKSHOP_MOD_IDS`. Configure base game
depots with `CK3QQBOT_BASE_GAME_DEPOT_IDS`; entries may be `depot_id` for latest
or `depot_id:manifest_id` for a pinned manifest. Leave
`CK3QQBOT_BASE_GAME_DEPOT_IDS` empty to skip all base-game depot downloads and
update only configured Workshop items.

SteamCMD can be quiet during `download_depot`. The updater polls sidecar task
state and logs a progress snapshot every
`CK3QQBOT_STEAMCMD_PROGRESS_INTERVAL_SEC` seconds, including elapsed time, task
state, target bytes, directory sizes, and free disk space.

Each configured base-game depot and each configured Workshop item is retried
in-place before the whole update fails. The defaults are:

```text
CK3QQBOT_STEAMCMD_DEPOT_ATTEMPTS=5
CK3QQBOT_STEAMCMD_WORKSHOP_ATTEMPTS=5
CK3QQBOT_STEAMCMD_RETRY_BACKOFF_SEC=30
```

In-place retries only repeat the failed depot or Workshop item. They do not
repeat successful items and they do not run the `CK3QQBOT_CLEAN_BEFORE_UPDATE`
cleanup step again, so SteamCMD can reuse partial files and its own cache. If
all attempts for the current item fail, the current update fails. The next
update run decides whether to clean only from `CK3QQBOT_CLEAN_BEFORE_UPDATE`;
it does not use `/update-state/FAILED` to override cleanup behavior.

When an update fails after `.updating` is written, the updater writes
`/update-state/FAILED` with metadata including the failed phase and item, the
current attempt number, planned depots and Workshop items, completed downloads,
completed prune passes, and the remaining unpruned items.

SteamCMD login is cache-oriented:

- mount the SteamCMD state volume at `/steam` in `steamcmd-sidecar`
- set `CK3QQBOT_STEAM_USER` in `.env`
- run `docker compose run --rm steamcmd-sidecar /usr/local/bin/ck3qqbot-steam-login`
  once to complete login and Steam Guard interactively
- run the updater with the same `.env`

The login and check scripts also accept a username argument as a temporary
override, but normal Docker Compose usage should read `CK3QQBOT_STEAM_USER`
from `.env`. The scripts do not accept Steam passwords or Steam Guard codes
through arguments or environment variables. If the cache expires, refresh it
with `ck3qqbot-steam-login` inside the `steamcmd-sidecar` container.

The updater acquires `/update-state/.update-lock` before running preflight
checks. It refuses to enter if `.updating` already exists, and it checks again
before writing `.updating`. This prevents a one-shot updater and
`updater-scheduler` from entering the same update concurrently while still
keeping login or disk preflight failures from leaving `.updating` behind.

The updater submits a sidecar `check-login` task before writing `.updating`.
The sidecar uses:

```text
+@ShutdownOnFailedCommand 1 +@NoPromptForPassword 1 +login $CK3QQBOT_STEAM_USER +quit
```

If the check fails, the update does not start. Run the login command inside
`steamcmd-sidecar` so the cache is written to the same persistent `/steam`
volume:

```bash
docker compose run --rm steamcmd-sidecar /usr/local/bin/ck3qqbot-steam-login
```

## Runtime Control

The updater does not control Docker. Runtime controls its own process lifetime with a lightweight watchdog:

```text
refuse if /update-state/.updating exists
acquire /update-state/.update-lock
steamcmd-sidecar check-login task
write /update-state/.updating
runtime watchdog observes .updating and stops cc-connect/Claude Code
runtime writes /update-state/.runtime-confirm
updater waits for /update-state/.runtime-confirm
optional cleanup of managed base_game/workshop directories
submit steamcmd-sidecar download_depot/workshop_download_item task + prune
write /update-state/READY, /knowledge/SUMMARY.txt, and /knowledge/MANIFEST.txt
remove /update-state/.updating and /update-state/.runtime-confirm
release /update-state/.update-lock
runtime waits CK3QQBOT_RUNTIME_RESTART_DELAY_SEC, then starts cc-connect/Claude Code again
```

This avoids mounting Docker's host-control socket into the updater:

```text
/var/run/docker.sock
```

On first deployment, start runtime before running the updater:

```bash
docker compose up -d runtime
```

If `/update-state/READY` does not exist yet and no update is active, runtime stays alive as a supervisor with internal services stopped and periodically logs that it is waiting. During an active update, it writes `/update-state/.runtime-confirm`; once updater finishes and writes `READY`, runtime starts internal services normally.

## Scheduler

`updater-scheduler` is a long-running container with an internal sleep loop. It avoids a host cron/systemd dependency while still using the same `update-now` path as manual updates.

Relevant variables:

```text
CK3QQBOT_UPDATE_INTERVAL_SEC=86400
CK3QQBOT_UPDATE_RUN_ON_START=false
CK3QQBOT_UPDATE_SCHEDULE_FROM_READY=true
CK3QQBOT_UPDATE_SCHEDULER_POLL_SEC=300
CK3QQBOT_UPDATE_FAILURE_BACKOFF_SEC=60
```

With `CK3QQBOT_UPDATE_SCHEDULE_FROM_READY=true`, the scheduler parses
`/update-state/READY` every `CK3QQBOT_UPDATE_SCHEDULER_POLL_SEC` seconds and
uses `ready_at + CK3QQBOT_UPDATE_INTERVAL_SEC` as the next automatic update
time. This keeps restarts from shifting the update cadence while still noticing
READY changes promptly. If the READY timestamp is already older than the
interval, the scheduler starts an update immediately. If READY is missing or
cannot be parsed, the scheduler distinguishes initialization from in-progress
updates: missing READY plus no `.updating` marker starts an initial update;
missing READY plus `.updating` waits one poll interval; READY due plus
`.updating` also waits one poll interval; an existing but unparseable READY also
waits instead of guessing. If an update attempt fails, or an attempt returns
without producing READY, the scheduler waits `CK3QQBOT_UPDATE_FAILURE_BACKOFF_SEC`
from the observed failure time before retrying. This keeps retries bounded and
guarantees each failed attempt has a minimum cool-down after it actually ends.
