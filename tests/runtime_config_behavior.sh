#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_exists() {
  [[ -e "$1" ]] || fail "expected path to exist: $1"
}

assert_same() {
  cmp -s "$1" "$2" || fail "expected files to match: $1 $2"
}

tmp="$(mktemp -d)"
input="${tmp}/config-input"
runtime="${tmp}/runtime/config"
bot="${tmp}/bot"
claude_home="${tmp}/runtime/claude-home"

mkdir -p "${input}/.claude"

cat > "${input}/cc-connect.toml" <<'EOF'
[[projects]]
name = "test"

[projects.agent]
type = "claudecode"
EOF

cat > "${input}/claude-settings.json" <<'EOF'
{
  "permissions": {
    "defaultMode": "auto"
  }
}
EOF

cat > "${input}/CLAUDE.md" <<'EOF'
# Bot Rules

Keep exact wording.
EOF

cat > "${input}/.claude/settings.json" <<'EOF'
{
  "disableArtifact": true
}
EOF

cat > "${input}/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "custom": {
      "command": "/mcp/custom/custom-mcp",
      "env": {
        "TEST_VALUE": "${TEST_MCP_VALUE}"
      }
    }
  }
}
EOF

env \
  CK3QQBOT_CONFIG_INPUT_DIR="${input}" \
  CK3QQBOT_RUNTIME_CONFIG_DIR="${runtime}" \
  CK3QQBOT_BOT_DIR="${bot}" \
  CK3QQBOT_CLAUDE_HOME="${claude_home}" \
  TEST_MCP_VALUE="expanded-value" \
  "${repo_root}/scripts/prepare-runtime-config"

assert_exists "${runtime}/cc-connect.toml"
assert_exists "${claude_home}/settings.json"
assert_exists "${bot}/CLAUDE.md"
assert_exists "${bot}/.claude/settings.json"
assert_exists "${bot}/.mcp.json"

assert_same "${input}/cc-connect.toml" "${runtime}/cc-connect.toml"
assert_same "${input}/claude-settings.json" "${claude_home}/settings.json"
assert_same "${input}/CLAUDE.md" "${bot}/CLAUDE.md"
assert_same "${input}/.claude/settings.json" "${bot}/.claude/settings.json"
grep -Fq '"TEST_VALUE": "expanded-value"' "${bot}/.mcp.json" || fail "expected project MCP env vars to be rendered"

echo "runtime config behavior tests passed"
