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

make_fake_steamcmd() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_STEAMCMD_LOG:?}"

if [[ -n "${FAKE_STEAMCMD_OUTPUT:-}" ]]; then
  printf '%s\n' "${FAKE_STEAMCMD_OUTPUT}"
fi

if [[ -n "${FAKE_STEAMCMD_EXIT:-}" ]]; then
  exit "${FAKE_STEAMCMD_EXIT}"
fi
EOF
  chmod +x "${path}"
}

test_success() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/bin"
  make_fake_steamcmd "${tmp}/bin/fake-steamcmd"

  env \
    CK3QQBOT_STEAMCMD_BIN="${tmp}/bin/fake-steamcmd" \
    CK3QQBOT_STEAMCMD_HOME="${tmp}/steam" \
    CK3QQBOT_STEAM_USER="test-user" \
    FAKE_STEAMCMD_LOG="${tmp}/steamcmd.log" \
    "${repo_root}/scripts/steam-check-login"

  assert_contains "${tmp}/steamcmd.log" "+@ShutdownOnFailedCommand 1"
  assert_contains "${tmp}/steamcmd.log" "+@NoPromptForPassword 1"
  assert_contains "${tmp}/steamcmd.log" "+login test-user"
}

test_failure_text() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/bin"
  make_fake_steamcmd "${tmp}/bin/fake-steamcmd"

  if env \
    CK3QQBOT_STEAMCMD_BIN="${tmp}/bin/fake-steamcmd" \
    CK3QQBOT_STEAMCMD_HOME="${tmp}/steam" \
    CK3QQBOT_STEAM_USER="test-user" \
    FAKE_STEAMCMD_LOG="${tmp}/steamcmd.log" \
    FAKE_STEAMCMD_OUTPUT="Steam Guard required" \
    "${repo_root}/scripts/steam-check-login"; then
    fail "expected steam-check-login to fail on Steam Guard text"
  fi
}

test_shutdown_on_failed_command_text_does_not_fail() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/bin"
  make_fake_steamcmd "${tmp}/bin/fake-steamcmd"

  env \
    CK3QQBOT_STEAMCMD_BIN="${tmp}/bin/fake-steamcmd" \
    CK3QQBOT_STEAMCMD_HOME="${tmp}/steam" \
    CK3QQBOT_STEAM_USER="test-user" \
    FAKE_STEAMCMD_LOG="${tmp}/steamcmd.log" \
    FAKE_STEAMCMD_OUTPUT="+@ShutdownOnFailedCommand 1" \
    "${repo_root}/scripts/steam-check-login"
}

test_failure_exit() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/bin"
  make_fake_steamcmd "${tmp}/bin/fake-steamcmd"

  if env \
    CK3QQBOT_STEAMCMD_BIN="${tmp}/bin/fake-steamcmd" \
    CK3QQBOT_STEAMCMD_HOME="${tmp}/steam" \
    CK3QQBOT_STEAM_USER="test-user" \
    FAKE_STEAMCMD_LOG="${tmp}/steamcmd.log" \
    FAKE_STEAMCMD_EXIT=42 \
    "${repo_root}/scripts/steam-check-login"; then
    fail "expected steam-check-login to fail on non-zero exit"
  fi
}

test_success
test_failure_text
test_shutdown_on_failed_command_text_does_not_fail
test_failure_exit

echo "steam-check-login behavior tests passed"
