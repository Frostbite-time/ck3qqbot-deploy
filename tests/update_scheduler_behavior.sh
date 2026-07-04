#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp="$(mktemp -d)"
cat > "${tmp}/fake-update" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'run\n' >> "${SCHEDULER_LOG:?}"
EOF
chmod +x "${tmp}/fake-update"

cat > "${tmp}/fake-failing-update" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'run\n' >> "${SCHEDULER_LOG:?}"
exit 42
EOF
chmod +x "${tmp}/fake-failing-update"

set +e
env \
  CK3QQBOT_UPDATE_BIN="${tmp}/fake-update" \
  CK3QQBOT_UPDATE_INTERVAL_SEC=9999 \
  CK3QQBOT_UPDATE_RUN_ON_START=true \
  SCHEDULER_LOG="${tmp}/scheduler.log" \
  timeout 1 "${repo_root}/scripts/update-scheduler" >/dev/null 2>&1
status="$?"
set -e

if [[ "${status}" != "124" ]]; then
  echo "FAIL: expected timeout exit 124, got ${status}" >&2
  exit 1
fi

grep -Fq "run" "${tmp}/scheduler.log"

rm -f "${tmp}/scheduler.log"
mkdir -p "${tmp}/update-state"
touch "${tmp}/update-state/.updating"

set +e
env \
  CK3QQBOT_UPDATE_BIN="${tmp}/fake-update" \
  CK3QQBOT_UPDATE_STATE_DIR="${tmp}/update-state" \
  CK3QQBOT_UPDATE_INTERVAL_SEC=9999 \
  CK3QQBOT_UPDATE_RUN_ON_START=true \
  CK3QQBOT_UPDATE_SCHEDULER_POLL_SEC=1 \
  SCHEDULER_LOG="${tmp}/scheduler.log" \
  timeout 2 "${repo_root}/scripts/update-scheduler" >/dev/null 2>&1
status="$?"
set -e

if [[ "${status}" != "124" ]]; then
  echo "FAIL: expected timeout exit 124 for run-on-start with update marker test, got ${status}" >&2
  exit 1
fi

if [[ -e "${tmp}/scheduler.log" ]]; then
  echo "FAIL: scheduler run-on-start should not run when update marker exists" >&2
  exit 1
fi

rm -f "${tmp}/scheduler.log" "${tmp}/update-state/.updating"
printf 'ready_at=2026-07-01T00:00:00Z\n' > "${tmp}/update-state/READY"

set +e
env \
  CK3QQBOT_UPDATE_BIN="${tmp}/fake-update" \
  CK3QQBOT_UPDATE_STATE_DIR="${tmp}/update-state" \
  CK3QQBOT_UPDATE_INTERVAL_SEC=60 \
  CK3QQBOT_UPDATE_RUN_ON_START=false \
  CK3QQBOT_SCHEDULER_NOW_EPOCH=1782864061 \
  SCHEDULER_LOG="${tmp}/scheduler.log" \
  timeout 1 "${repo_root}/scripts/update-scheduler" >/dev/null 2>&1
status="$?"
set -e

if [[ "${status}" != "124" ]]; then
  echo "FAIL: expected timeout exit 124 for due READY test, got ${status}" >&2
  exit 1
fi

grep -Fq "run" "${tmp}/scheduler.log"

rm -f "${tmp}/scheduler.log"
printf 'ready_at=2026-07-01T00:00:00Z\n' > "${tmp}/update-state/READY"
touch "${tmp}/update-state/.updating"

set +e
env \
  CK3QQBOT_UPDATE_BIN="${tmp}/fake-update" \
  CK3QQBOT_UPDATE_STATE_DIR="${tmp}/update-state" \
  CK3QQBOT_UPDATE_INTERVAL_SEC=60 \
  CK3QQBOT_UPDATE_RUN_ON_START=false \
  CK3QQBOT_UPDATE_SCHEDULER_POLL_SEC=1 \
  CK3QQBOT_SCHEDULER_NOW_EPOCH=1782864061 \
  SCHEDULER_LOG="${tmp}/scheduler.log" \
  timeout 2 "${repo_root}/scripts/update-scheduler" >/dev/null 2>&1
status="$?"
set -e

if [[ "${status}" != "124" ]]; then
  echo "FAIL: expected timeout exit 124 for due READY with update marker test, got ${status}" >&2
  exit 1
fi

if [[ -e "${tmp}/scheduler.log" ]]; then
  echo "FAIL: scheduler should not run when READY is due but update marker exists" >&2
  exit 1
fi

rm -f "${tmp}/scheduler.log" "${tmp}/update-state/.updating"
printf 'ready_at=2026-07-01T00:00:00Z\n' > "${tmp}/update-state/READY"

set +e
env \
  CK3QQBOT_UPDATE_BIN="${tmp}/fake-update" \
  CK3QQBOT_UPDATE_STATE_DIR="${tmp}/update-state" \
  CK3QQBOT_UPDATE_INTERVAL_SEC=9999 \
  CK3QQBOT_UPDATE_RUN_ON_START=false \
  CK3QQBOT_UPDATE_SCHEDULER_POLL_SEC=1 \
  CK3QQBOT_SCHEDULER_NOW_EPOCH=1782864000 \
  SCHEDULER_LOG="${tmp}/scheduler.log" \
  timeout 1 "${repo_root}/scripts/update-scheduler" >/dev/null 2>&1
status="$?"
set -e

if [[ "${status}" != "124" ]]; then
  echo "FAIL: expected timeout exit 124 for pending READY test, got ${status}" >&2
  exit 1
fi

if [[ -e "${tmp}/scheduler.log" ]]; then
  echo "FAIL: scheduler should not run before READY-based interval is due" >&2
  exit 1
fi

rm -f "${tmp}/scheduler.log" "${tmp}/update-state/READY"

set +e
env \
  CK3QQBOT_UPDATE_BIN="${tmp}/fake-update" \
  CK3QQBOT_UPDATE_STATE_DIR="${tmp}/update-state" \
  CK3QQBOT_UPDATE_INTERVAL_SEC=1 \
  CK3QQBOT_UPDATE_RUN_ON_START=false \
  CK3QQBOT_UPDATE_SCHEDULER_POLL_SEC=1 \
  CK3QQBOT_SCHEDULER_NOW_EPOCH=1782864000 \
  SCHEDULER_LOG="${tmp}/scheduler.log" \
  timeout 2 "${repo_root}/scripts/update-scheduler" >/dev/null 2>&1
status="$?"
set -e

if [[ "${status}" != "124" ]]; then
  echo "FAIL: expected timeout exit 124 for missing READY test, got ${status}" >&2
  exit 1
fi

grep -Fq "run" "${tmp}/scheduler.log"

rm -f "${tmp}/scheduler.log" "${tmp}/update-state/READY"

set +e
env \
  CK3QQBOT_UPDATE_BIN="${tmp}/fake-failing-update" \
  CK3QQBOT_UPDATE_STATE_DIR="${tmp}/update-state" \
  CK3QQBOT_UPDATE_INTERVAL_SEC=1 \
  CK3QQBOT_UPDATE_RUN_ON_START=false \
  CK3QQBOT_UPDATE_SCHEDULER_POLL_SEC=1 \
  CK3QQBOT_UPDATE_FAILURE_BACKOFF_SEC=10 \
  CK3QQBOT_SCHEDULER_NOW_EPOCH=1782864000 \
  SCHEDULER_LOG="${tmp}/scheduler.log" \
  timeout 2 "${repo_root}/scripts/update-scheduler" >/dev/null 2>&1
status="$?"
set -e

if [[ "${status}" != "124" ]]; then
  echo "FAIL: expected timeout exit 124 for missing READY failed update backoff test, got ${status}" >&2
  exit 1
fi

run_count="$(wc -l < "${tmp}/scheduler.log")"
if [[ "${run_count}" != "1" ]]; then
  echo "FAIL: scheduler should back off after failed update, got ${run_count} runs" >&2
  exit 1
fi

rm -f "${tmp}/scheduler.log" "${tmp}/update-state/READY"
touch "${tmp}/update-state/.updating"

set +e
env \
  CK3QQBOT_UPDATE_BIN="${tmp}/fake-update" \
  CK3QQBOT_UPDATE_STATE_DIR="${tmp}/update-state" \
  CK3QQBOT_UPDATE_INTERVAL_SEC=1 \
  CK3QQBOT_UPDATE_RUN_ON_START=false \
  CK3QQBOT_UPDATE_SCHEDULER_POLL_SEC=1 \
  CK3QQBOT_SCHEDULER_NOW_EPOCH=1782864000 \
  SCHEDULER_LOG="${tmp}/scheduler.log" \
  timeout 2 "${repo_root}/scripts/update-scheduler" >/dev/null 2>&1
status="$?"
set -e

if [[ "${status}" != "124" ]]; then
  echo "FAIL: expected timeout exit 124 for missing READY with update marker test, got ${status}" >&2
  exit 1
fi

if [[ -e "${tmp}/scheduler.log" ]]; then
  echo "FAIL: scheduler should not run when READY is missing but update marker exists" >&2
  exit 1
fi

rm -f "${tmp}/scheduler.log" "${tmp}/update-state/.updating"
printf 'ready_at=not-a-date\n' > "${tmp}/update-state/READY"

set +e
env \
  CK3QQBOT_UPDATE_BIN="${tmp}/fake-update" \
  CK3QQBOT_UPDATE_STATE_DIR="${tmp}/update-state" \
  CK3QQBOT_UPDATE_INTERVAL_SEC=1 \
  CK3QQBOT_UPDATE_RUN_ON_START=false \
  CK3QQBOT_UPDATE_SCHEDULER_POLL_SEC=1 \
  CK3QQBOT_SCHEDULER_NOW_EPOCH=1782864000 \
  SCHEDULER_LOG="${tmp}/scheduler.log" \
  timeout 2 "${repo_root}/scripts/update-scheduler" >/dev/null 2>&1
status="$?"
set -e

if [[ "${status}" != "124" ]]; then
  echo "FAIL: expected timeout exit 124 for unparseable READY test, got ${status}" >&2
  exit 1
fi

if [[ -e "${tmp}/scheduler.log" ]]; then
  echo "FAIL: scheduler should not run when READY exists but cannot be parsed" >&2
  exit 1
fi

echo "update-scheduler behavior tests passed"
