#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -Fq -- "$pattern" "$file" || fail "expected ${file} to contain ${pattern}"
}

assert_exists() {
  [[ -e "$1" ]] || fail "expected path to exist: $1"
}

tmp="$(mktemp -d)"
mkdir -p "${tmp}/bin" "${tmp}/runtime/config" "${tmp}/update-state"

cat > "${tmp}/bin/fake-doctor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'doctor\n' >> "${START_LOG:?}"
EOF

cat > "${tmp}/bin/fake-prepare" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'prepare\n' >> "${START_LOG:?}"
EOF

cat > "${tmp}/bin/fake-cc-connect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cc-connect %s\n' "$*" >> "${START_LOG:?}"
EOF

chmod +x "${tmp}/bin/fake-doctor" "${tmp}/bin/fake-prepare" "${tmp}/bin/fake-cc-connect"

env \
  START_LOG="${tmp}/start.log" \
  CK3QQBOT_DOCTOR_BIN="${tmp}/bin/fake-doctor" \
  CK3QQBOT_PREPARE_RUNTIME_CONFIG_BIN="${tmp}/bin/fake-prepare" \
  CK3QQBOT_CC_CONNECT_BIN="${tmp}/bin/fake-cc-connect" \
  CK3QQBOT_RUNTIME_CONFIG_DIR="${tmp}/runtime/config" \
  CK3QQBOT_UPDATE_STATE_DIR="${tmp}/update-state" \
  "${repo_root}/scripts/start"

assert_contains "${tmp}/start.log" "doctor"
assert_contains "${tmp}/start.log" "prepare"
assert_contains "${tmp}/start.log" "cc-connect --config ${tmp}/runtime/config/cc-connect.toml"

ready_tmp="$(mktemp -d)"
mkdir -p "${ready_tmp}/bin" "${ready_tmp}/runtime/config" "${ready_tmp}/knowledge" "${ready_tmp}/update-state"

cat > "${ready_tmp}/bin/fake-doctor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'doctor\n' >> "${START_LOG:?}"
if [[ ! -e "${UPDATE_STATE_DIR:?}/READY" ]]; then
  printf 'not-ready\n' >> "${START_LOG:?}"
  exit 21
fi
EOF

cat > "${ready_tmp}/bin/fake-prepare" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'prepare\n' >> "${START_LOG:?}"
EOF

cat > "${ready_tmp}/bin/fake-cc-connect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cc-connect-start\n' >> "${START_LOG:?}"
trap 'exit 0' TERM
while true; do
  sleep 1
done
EOF

chmod +x "${ready_tmp}/bin/fake-doctor" "${ready_tmp}/bin/fake-prepare" "${ready_tmp}/bin/fake-cc-connect"

env \
  START_LOG="${ready_tmp}/start.log" \
  UPDATE_STATE_DIR="${ready_tmp}/update-state" \
  CK3QQBOT_DOCTOR_BIN="${ready_tmp}/bin/fake-doctor" \
  CK3QQBOT_PREPARE_RUNTIME_CONFIG_BIN="${ready_tmp}/bin/fake-prepare" \
  CK3QQBOT_CC_CONNECT_BIN="${ready_tmp}/bin/fake-cc-connect" \
  CK3QQBOT_RUNTIME_CONFIG_DIR="${ready_tmp}/runtime/config" \
  CK3QQBOT_KNOWLEDGE_DIR="${ready_tmp}/knowledge" \
  CK3QQBOT_UPDATE_STATE_DIR="${ready_tmp}/update-state" \
  CK3QQBOT_RUNTIME_WATCHDOG_INTERVAL_SEC=1 \
  "${repo_root}/scripts/start" &
ready_pid="$!"

sleep 2
if grep -Fq "cc-connect-start" "${ready_tmp}/start.log"; then
  kill "${ready_pid}" 2>/dev/null || true
  fail "runtime services should not start before READY exists"
fi
kill -0 "${ready_pid}" 2>/dev/null || fail "runtime supervisor should keep running while READY is missing"

printf 'ready\n' > "${ready_tmp}/update-state/READY"
for _ in {1..30}; do
  if grep -Fq "cc-connect-start" "${ready_tmp}/start.log"; then
    break
  fi
  sleep 0.2
done

assert_contains "${ready_tmp}/start.log" "cc-connect-start"
kill "${ready_pid}" 2>/dev/null || true
wait "${ready_pid}" 2>/dev/null || true

watch_tmp="$(mktemp -d)"
mkdir -p "${watch_tmp}/bin" "${watch_tmp}/runtime/config" "${watch_tmp}/knowledge"

cat > "${watch_tmp}/bin/fake-doctor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'doctor\n' >> "${START_LOG:?}"
EOF

cat > "${watch_tmp}/bin/fake-prepare" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'prepare\n' >> "${START_LOG:?}"
EOF

cat > "${watch_tmp}/bin/fake-cc-connect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cc-connect-start\n' >> "${START_LOG:?}"
trap 'printf "cc-connect-term\n" >> "${START_LOG:?}"; exit 0' TERM
while true; do
  sleep 1
done
EOF

chmod +x "${watch_tmp}/bin/fake-doctor" "${watch_tmp}/bin/fake-prepare" "${watch_tmp}/bin/fake-cc-connect"

env \
  START_LOG="${watch_tmp}/start.log" \
  CK3QQBOT_DOCTOR_BIN="${watch_tmp}/bin/fake-doctor" \
  CK3QQBOT_PREPARE_RUNTIME_CONFIG_BIN="${watch_tmp}/bin/fake-prepare" \
  CK3QQBOT_CC_CONNECT_BIN="${watch_tmp}/bin/fake-cc-connect" \
  CK3QQBOT_RUNTIME_CONFIG_DIR="${watch_tmp}/runtime/config" \
  CK3QQBOT_KNOWLEDGE_DIR="${watch_tmp}/knowledge" \
  CK3QQBOT_UPDATE_STATE_DIR="${watch_tmp}/update-state" \
  CK3QQBOT_RUNTIME_WATCHDOG_INTERVAL_SEC=1 \
  CK3QQBOT_RUNTIME_RESTART_DELAY_SEC=1 \
  "${repo_root}/scripts/start" &
start_pid="$!"

for _ in {1..20}; do
  if [[ -f "${watch_tmp}/start.log" ]] && grep -Fq "cc-connect-start" "${watch_tmp}/start.log"; then
    break
  fi
  sleep 0.2
done

printf 'updating\n' > "${watch_tmp}/update-state/.updating"

for _ in {1..30}; do
  if [[ -e "${watch_tmp}/update-state/.runtime-confirm" ]] && grep -Fq "cc-connect-term" "${watch_tmp}/start.log"; then
    break
  fi
  sleep 0.2
done

assert_exists "${watch_tmp}/update-state/.runtime-confirm"
assert_contains "${watch_tmp}/start.log" "cc-connect-term"

starts_before="$(grep -Fc "cc-connect-start" "${watch_tmp}/start.log")"
rm -f "${watch_tmp}/update-state/.updating" "${watch_tmp}/update-state/.runtime-confirm"

for _ in {1..40}; do
  starts_after="$(grep -Fc "cc-connect-start" "${watch_tmp}/start.log")"
  if (( starts_after > starts_before )); then
    break
  fi
  sleep 0.2
done

starts_after="$(grep -Fc "cc-connect-start" "${watch_tmp}/start.log")"
if (( starts_after <= starts_before )); then
  kill "${start_pid}" 2>/dev/null || true
  fail "expected runtime services to restart after .updating was removed"
fi

kill "${start_pid}" 2>/dev/null || true
wait "${start_pid}" 2>/dev/null || true

echo "runtime start behavior tests passed"
