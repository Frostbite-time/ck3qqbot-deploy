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

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -Fq -- "$pattern" "$file" || fail "expected ${file} to contain ${pattern}"
}

tmp="$(mktemp -d)"
mkdir -p "${tmp}/bin"

cat > "${tmp}/bin/fake-steamcmd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" > "${FAKE_STEAMCMD_LOG:?}"

install_dir=""
args=("$@")
for ((index = 0; index < ${#args[@]}; index++)); do
  case "${args[$index]}" in
    +force_install_dir)
      index=$((index + 1))
      install_dir="${args[$index]}"
      ;;
    +app_update)
      mkdir -p "${install_dir}"
      printf 'game\n' > "${install_dir}/game.txt"
      ;;
    +download_item)
      app_id="${args[$((index + 1))]}"
      item_id="${args[$((index + 2))]}"
      mkdir -p "${FAKE_DIRECT_CONTENT_ROOT:?}/app_${app_id}/item_${item_id}"
      printf 'direct-item\n' > "${FAKE_DIRECT_CONTENT_ROOT}/app_${app_id}/item_${item_id}/item.txt"
      ;;
  esac
done
EOF
chmod +x "${tmp}/bin/fake-steamcmd"

env \
  CK3QQBOT_STEAMCMD_BIN="${tmp}/bin/fake-steamcmd" \
  CK3QQBOT_STEAMCMD_HOME="${tmp}/steam" \
  CK3QQBOT_STEAM_USER="test-user" \
  CK3QQBOT_STEAM_SMOKE_DIR="${tmp}/download" \
  CK3QQBOT_STEAM_SMOKE_REPORT_DIR="${tmp}/reports" \
  CK3QQBOT_STEAM_SMOKE_MIN_FREE_KIB=0 \
  CK3QQBOT_STEAMCMD_DIRECT_ITEM_CONTENT_ROOT="${tmp}/direct-content" \
  FAKE_DIRECT_CONTENT_ROOT="${tmp}/direct-content" \
  FAKE_STEAMCMD_LOG="${tmp}/fake-steamcmd.log" \
  "${repo_root}/scripts/steam-smoke-download"

assert_exists "${tmp}/download/game/game.txt"
assert_exists "${tmp}/direct-content/app_1079000/item_2339078416/item.txt"
assert_exists "${tmp}/reports/SUMMARY.txt"
assert_exists "${tmp}/reports/steamcmd.log"
assert_contains "${tmp}/fake-steamcmd.log" "+login test-user"
assert_contains "${tmp}/fake-steamcmd.log" "+app_license_request 1079000"
assert_contains "${tmp}/fake-steamcmd.log" "+app_update 1079000 validate"
assert_contains "${tmp}/fake-steamcmd.log" "+download_item 1079000 2339078416"
assert_contains "${tmp}/reports/SUMMARY.txt" "AppID: 1079000"
assert_contains "${tmp}/reports/SUMMARY.txt" "WorkshopItemID: 2339078416"

echo "steam-smoke-download behavior tests passed"

