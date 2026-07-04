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

dockerfile="${repo_root}/Dockerfile.runtime"

assert_contains "${dockerfile}" "FROM node:22-bookworm-slim"
assert_contains "${dockerfile}" "ARG CLAUDE_CODE_VERSION=2.1.198"
assert_contains "${dockerfile}" "DISABLE_AUTOUPDATER=1"
assert_contains "${dockerfile}" "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1"
assert_contains "${dockerfile}" "bubblewrap socat"
assert_contains "${dockerfile}" "jq"
assert_contains "${dockerfile}" "COPY scripts/install-claude-code /usr/local/bin/install-claude-code"
assert_contains "${dockerfile}" '/usr/local/bin/install-claude-code "${CLAUDE_CODE_VERSION}"'
assert_contains "${dockerfile}" "COPY scripts/runtime-entrypoint /usr/local/bin/ck3qqbot-runtime-entrypoint"
assert_contains "${dockerfile}" "ENTRYPOINT [\"/usr/local/bin/ck3qqbot-runtime-entrypoint\"]"
assert_contains "${dockerfile}" "chown -R node:node /bot /home/node"
assert_contains "${repo_root}/scripts/runtime-entrypoint" "/bot/steam-downloads"

echo "runtime image behavior tests passed"
