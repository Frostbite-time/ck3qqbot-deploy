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

tmp="$(mktemp -d)"
release="${tmp}/release"
version="9.8.7"
platform="linux-x64"
binary_dir="${release}/${version}/${platform}"
install_path="${tmp}/bin/claude"
mkdir -p "${binary_dir}" "${tmp}/bin"

cat > "${binary_dir}/claude" <<'EOF'
#!/usr/bin/env bash
echo "9.8.7 (Claude Code)"
EOF
chmod +x "${binary_dir}/claude"

checksum="$(sha256sum "${binary_dir}/claude" | awk '{ print $1 }')"
cat > "${release}/${version}/manifest.json" <<EOF
{
  "platforms": {
    "${platform}": {
      "binary": "claude",
      "checksum": "${checksum}",
      "size": 1
    }
  }
}
EOF

CLAUDE_CODE_DOWNLOAD_BASE_URL="file://${release}" \
CLAUDE_CODE_INSTALL_PATH="${install_path}" \
  "${repo_root}/scripts/install-claude-code" "${version}" >"${tmp}/install.log"

[[ -x "${install_path}" ]] || fail "expected installed claude binary to be executable"
assert_contains "${tmp}/install.log" "OK"
assert_contains "${tmp}/install.log" "9.8.7 (Claude Code)"

echo "install-claude-code behavior tests passed"
