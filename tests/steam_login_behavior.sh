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

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -Fq -- "$pattern" "$file"; then
    fail "expected ${file} not to contain ${pattern}"
  fi
}

tmp="$(mktemp -d)"
mkdir -p "${tmp}/bin"

cat > "${tmp}/bin/fake-steamcmd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'HOME=%s\n' "${HOME}" >> "${FAKE_STEAMCMD_LOG:?}"
printf 'ARGS=%s\n' "$*" >> "${FAKE_STEAMCMD_LOG:?}"
EOF

chmod +x "${tmp}/bin/fake-steamcmd"

env \
  CK3QQBOT_STEAMCMD_BIN="${tmp}/bin/fake-steamcmd" \
  CK3QQBOT_STEAMCMD_HOME="${tmp}/steam" \
  FAKE_STEAMCMD_LOG="${tmp}/steamcmd.log" \
  "${repo_root}/scripts/steam-login" "test-user"

assert_contains "${tmp}/steamcmd.log" "HOME=${tmp}/steam"
assert_contains "${tmp}/steamcmd.log" "ARGS=+login test-user +quit"
assert_not_contains "${tmp}/steamcmd.log" "password"
assert_not_contains "${tmp}/steamcmd.log" "guard"

echo "steam-login behavior tests passed"

