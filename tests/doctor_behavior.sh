#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp="$(mktemp -d)"
knowledge="${tmp}/knowledge"
update_state="${tmp}/update-state"
mkdir -p "${knowledge}" "${update_state}"

if env CK3QQBOT_KNOWLEDGE_DIR="${knowledge}" CK3QQBOT_UPDATE_STATE_DIR="${update_state}" "${repo_root}/scripts/doctor"; then
  fail "expected doctor to fail when READY is missing"
fi

printf 'ready\n' > "${update_state}/READY"
env CK3QQBOT_KNOWLEDGE_DIR="${knowledge}" CK3QQBOT_UPDATE_STATE_DIR="${update_state}" "${repo_root}/scripts/doctor" >/dev/null

printf 'updating\n' > "${update_state}/.updating"
if env CK3QQBOT_KNOWLEDGE_DIR="${knowledge}" CK3QQBOT_UPDATE_STATE_DIR="${update_state}" "${repo_root}/scripts/doctor"; then
  fail "expected doctor to fail when .updating exists"
fi

env \
  CK3QQBOT_KNOWLEDGE_DIR="${knowledge}" \
  CK3QQBOT_UPDATE_STATE_DIR="${update_state}" \
  CK3QQBOT_FORCE_START=true \
  "${repo_root}/scripts/doctor" >/dev/null

echo "doctor behavior tests passed"
