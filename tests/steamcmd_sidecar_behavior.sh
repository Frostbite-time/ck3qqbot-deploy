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

assert_missing() {
  [[ ! -e "$1" ]] || fail "expected path to be missing: $1"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  ! grep -Fq -- "$pattern" "$file" || fail "expected ${file} not to contain ${pattern}"
}

tmp="$(mktemp -d)"
mkdir -p "${tmp}/bin" "${tmp}/steam" "${tmp}/downloads" "${tmp}/knowledge"

cat > "${tmp}/bin/fake-steamcmd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'HOME=%s ARGS=%s\n' "${HOME}" "$*" >> "${FAKE_STEAMCMD_LOG:?}"

args=("$@")
for ((index = 0; index < ${#args[@]}; index++)); do
  case "${args[$index]}" in
    +workshop_download_item)
      app_id="${args[$((index + 1))]}"
      item_id="${args[$((index + 2))]}"
      target="${HOME}/Steam/steamapps/workshop/content/${app_id}/${item_id}"
      mkdir -p "${target}"
      printf 'workshop=%s\n' "${item_id}" > "${target}/item.txt"
      ;;
    +download_depot)
      depot_root="${args[$((index + 5))]}"
      mkdir -p "${depot_root}"
      printf 'depot\n' > "${depot_root}/depot.txt"
      ;;
    +app_update)
      install_dir=""
      for ((scan = 0; scan < ${#args[@]}; scan++)); do
        if [[ "${args[$scan]}" == "+force_install_dir" ]]; then
          install_dir="${args[$((scan + 1))]}"
        fi
      done
      mkdir -p "${install_dir}"
      printf 'app\n' > "${install_dir}/app.txt"
      ;;
    +app_info_print)
      app_id="${args[$((index + 1))]}"
      cat <<APPINFO
"appid" "${app_id}"
"depots"
{
  "1158311"
  {
    "manifests"
    {
      "public"
      {
        "gid" "123456789"
        "size" "2048"
        "download" "1024"
      }
    }
  }
  "1158312"
  {
    "manifests"
    {
      "public"
      {
        "gid" "987654321"
        "size" "20480"
        "download" "10240"
      }
    }
  }
}
APPINFO
      ;;
  esac
done
EOF
chmod +x "${tmp}/bin/fake-steamcmd"

npm --prefix "${repo_root}/tools/steamcmd-sidecar" run build >/dev/null

port="$((23000 + RANDOM % 10000))"
api_port="$((34000 + RANDOM % 10000))"
FAKE_WORKSHOP_API_PORT="${api_port}" node -e '
const http = require("node:http");
http.createServer((req, res) => {
  let body = "";
  req.on("data", chunk => body += chunk);
  req.on("end", () => {
    const itemId = new URLSearchParams(body).get("publishedfileids[0]");
    const fileSize = itemId === "999" ? "20480" : "2048";
    res.writeHead(200, {"content-type": "application/json"});
    res.end(JSON.stringify({response: {result: 1, resultcount: 1, publishedfiledetails: [{
      publishedfileid: itemId,
      result: 1,
      consumer_app_id: 1158310,
      file_size: fileSize
    }]}}));
  });
}).listen(Number(process.env.FAKE_WORKSHOP_API_PORT), "127.0.0.1");
' &
api_pid="$!"
(
  cd "${repo_root}"
  env \
    CK3QQBOT_STEAMCMD_MCP_HOST=127.0.0.1 \
    CK3QQBOT_STEAMCMD_MCP_PORT="${port}" \
    CK3QQBOT_STEAMCMD_MCP_TOKEN="mcp-test-token" \
    CK3QQBOT_STEAMCMD_MCP_MAX_DOWNLOAD_KIB="10" \
    CK3QQBOT_STEAMCMD_MCP_RUNTIME_DOWNLOAD_ROOT="/bot/steam-downloads" \
    CK3QQBOT_STEAMCMD_INTERNAL_TOKEN="internal-test-token" \
    CK3QQBOT_STEAM_USER="test-user" \
    CK3QQBOT_STEAMCMD_BIN="${tmp}/bin/fake-steamcmd" \
    CK3QQBOT_STEAMCMD_HOME="${tmp}/steam" \
    CK3QQBOT_STEAMCMD_DOWNLOAD_ROOT="${tmp}/downloads" \
    CK3QQBOT_KNOWLEDGE_DIR="${tmp}/knowledge" \
    CK3QQBOT_STEAM_WORKSHOP_DETAILS_URL="http://127.0.0.1:${api_port}/details" \
    FAKE_STEAMCMD_LOG="${tmp}/steamcmd.log" \
    node tools/steamcmd-sidecar/dist/index.js >"${tmp}/sidecar.log" 2>&1
) &
server_pid="$!"
trap 'kill "${server_pid}" "${api_pid}" 2>/dev/null || true' EXIT

for _ in {1..50}; do
  if curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null || {
  cat "${tmp}/sidecar.log" >&2
  fail "sidecar did not start on configured port ${port}"
}

unauthorized_status="$(
  curl -sS -o /dev/null -w '%{http_code}' \
    -H 'Authorization: Bearer wrong-token' \
    -H 'Content-Type: application/json' \
    -X POST \
    --data '{}' \
    "http://127.0.0.1:${port}/v1/internal/tasks/check-login"
)"
[[ "${unauthorized_status}" == "401" ]] || fail "expected unauthorized status 401, got ${unauthorized_status}"

post_task() {
  local endpoint="$1"
  local body="$2"
  curl -fsS \
    -H 'Authorization: Bearer internal-test-token' \
    -H 'Content-Type: application/json' \
    -X POST \
    --data "${body}" \
    "http://127.0.0.1:${port}${endpoint}"
}

get_task() {
  local id="$1"
  curl -fsS \
    -H 'Authorization: Bearer internal-test-token' \
    "http://127.0.0.1:${port}/v1/internal/tasks/${id}"
}

wait_task() {
  local id="$1"
  local json
  local state
  for _ in {1..50}; do
    json="$(get_task "${id}")"
    state="$(jq -r '.state' <<< "${json}")"
    case "${state}" in
      succeeded)
        return 0
        ;;
      failed | cancelled)
        echo "${json}" >&2
        return 1
        ;;
    esac
    sleep 0.1
  done
  fail "task ${id} did not finish"
}

mcp_response_json() {
  sed -n 's/^data: //p' "$1"
}

login_id="$(post_task "/v1/internal/tasks/check-login" '{}' | jq -r '.id')"
wait_task "${login_id}"

mkdir -p \
  "${tmp}/steam/Steam/steamapps/workshop/downloads/1158310/111" \
  "${tmp}/steam/Steam/steamapps/workshop/temp/1158310" \
  "${tmp}/steam/Steam/steamapps/workshop/content" \
  "${tmp}/knowledge/workshop_content"
ln -s "${tmp}/knowledge/workshop_content" "${tmp}/steam/Steam/steamapps/workshop/content/1158310"
printf 'state\n' > "${tmp}/steam/Steam/steamapps/workshop/appworkshop_1158310.acf"
printf 'patch\n' > "${tmp}/steam/Steam/steamapps/workshop/downloads/state_1158310_1158310_111.patch"
printf 'other app state\n' > "${tmp}/steam/Steam/steamapps/workshop/appworkshop_1079000.acf"
reset_body='{"appId":"1158310"}'
reset_response="$(post_task "/v1/internal/workshop-state/reset" "${reset_body}")"
[[ "$(jq -r '.ok' <<< "${reset_response}")" == "true" ]] || fail "expected workshop reset ok response"
assert_missing "${tmp}/steam/Steam/steamapps/workshop/appworkshop_1158310.acf"
assert_missing "${tmp}/steam/Steam/steamapps/workshop/downloads/1158310"
assert_missing "${tmp}/steam/Steam/steamapps/workshop/temp/1158310"
assert_missing "${tmp}/steam/Steam/steamapps/workshop/downloads/state_1158310_1158310_111.patch"
assert_exists "${tmp}/steam/Steam/steamapps/workshop/content/1158310"
assert_exists "${tmp}/steam/Steam/steamapps/workshop/appworkshop_1079000.acf"

rm -f "${tmp}/steam/Steam/steamapps/workshop/content/1158310"
printf '%s' "${tmp}/knowledge/workshop_broken" > "${tmp}/steam/Steam/steamapps/workshop/content/1158310"
broken_target="${tmp}/knowledge/workshop_broken"
broken_body="$(jq -cn --arg targetDir "${broken_target}" '{appId:"1158310", itemId:"101", targetDir:$targetDir}')"
broken_id="$(post_task "/v1/internal/tasks/download-workshop" "${broken_body}" | jq -r '.id')"
wait_task "${broken_id}"
assert_exists "${broken_target}/101/item.txt"
[[ -L "${tmp}/steam/Steam/steamapps/workshop/content/1158310" ]] || fail "expected broken workshop content file to be replaced with sidecar symlink"

first_target="${tmp}/knowledge/workshop_a"
first_body="$(jq -cn --arg targetDir "${first_target}" '{appId:"1158310", itemId:"111", targetDir:$targetDir}')"
first_id="$(post_task "/v1/internal/tasks/download-workshop" "${first_body}" | jq -r '.id')"
wait_task "${first_id}"
assert_exists "${first_target}/111/item.txt"

second_target="${tmp}/downloads/workshop_b"
second_body="$(jq -cn --arg targetDir "${second_target}" '{appId:"1158310", itemId:"222", targetDir:$targetDir}')"
second_id="$(post_task "/v1/internal/tasks/download-workshop" "${second_body}" | jq -r '.id')"
wait_task "${second_id}"
assert_exists "${second_target}/222/item.txt"

depot_target="${tmp}/knowledge/base_game"
depot_body="$(jq -cn --arg targetDir "${depot_target}" '{appId:"1158310", depotId:"1158311", targetDir:$targetDir}')"
depot_id="$(post_task "/v1/internal/tasks/download-depot" "${depot_body}" | jq -r '.id')"
wait_task "${depot_id}"
assert_exists "${depot_target}/depot.txt"

mcp_status="$(
  curl -sS -o /dev/null -w '%{http_code}' \
    -H 'Authorization: Bearer wrong-token' \
    -H 'Content-Type: application/json' \
    -X POST \
    --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
    "http://127.0.0.1:${port}/mcp"
)"
[[ "${mcp_status}" == "401" ]] || fail "expected MCP unauthorized status 401, got ${mcp_status}"

mcp_tools_response="${tmp}/mcp-tools.txt"
curl -fsS \
  -H 'Authorization: Bearer mcp-test-token' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  "http://127.0.0.1:${port}/mcp" > "${mcp_tools_response}"
assert_not_contains "${mcp_tools_response}" "steamcmd_download_app"
assert_contains "${mcp_tools_response}" "steamcmd_download_depot"
assert_contains "${mcp_tools_response}" "steamcmd_download_workshop_item"

mcp_depot_response="${tmp}/mcp-depot.txt"
curl -fsS \
  -H 'Authorization: Bearer mcp-test-token' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"steamcmd_download_depot","arguments":{"appId":"1158310","depotId":"1158311","targetSubdir":"mcp_depot"}}}' \
  "http://127.0.0.1:${port}/mcp" > "${mcp_depot_response}"
assert_contains "${mcp_depot_response}" "preflight"
assert_contains "${mcp_depot_response}" "sizeKiB"
assert_contains "${mcp_depot_response}" "/bot/steam-downloads/mcp_depot"
mcp_depot_id="$(mcp_response_json "${mcp_depot_response}" | jq -r '.result.content[0].text | fromjson | .id')"
wait_task "${mcp_depot_id}"
assert_exists "${tmp}/downloads/mcp_depot/depot.txt"
[[ "$(stat -c '%a' "${tmp}/downloads/mcp_depot")" == "777" ]] || fail "expected MCP depot download directory to be shared-writable"

mcp_depot_rejected_response="${tmp}/mcp-depot-rejected.txt"
curl -fsS \
  -H 'Authorization: Bearer mcp-test-token' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"steamcmd_download_depot","arguments":{"appId":"1158310","depotId":"1158312","targetSubdir":"mcp_depot_rejected"}}}' \
  "http://127.0.0.1:${port}/mcp" > "${mcp_depot_rejected_response}"
assert_contains "${mcp_depot_rejected_response}" "over configured limit 10 KiB"
[[ ! -e "${tmp}/downloads/mcp_depot_rejected" ]] || fail "rejected MCP depot download should not create target directory"

mcp_workshop_response="${tmp}/mcp-workshop.txt"
curl -fsS \
  -H 'Authorization: Bearer mcp-test-token' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"steamcmd_download_workshop_item","arguments":{"appId":"1158310","itemId":"333","targetSubdir":"mcp_workshop"}}}' \
  "http://127.0.0.1:${port}/mcp" > "${mcp_workshop_response}"
assert_contains "${mcp_workshop_response}" "preflight"
assert_contains "${mcp_workshop_response}" "sizeKiB"
assert_contains "${mcp_workshop_response}" "/bot/steam-downloads/mcp_workshop/333"
mcp_workshop_id="$(mcp_response_json "${mcp_workshop_response}" | jq -r '.result.content[0].text | fromjson | .id')"
wait_task "${mcp_workshop_id}"
assert_exists "${tmp}/downloads/mcp_workshop/333/item.txt"
[[ "$(stat -c '%a' "${tmp}/downloads/mcp_workshop")" == "777" ]] || fail "expected MCP workshop download directory to be shared-writable"

mcp_rejected_response="${tmp}/mcp-rejected.txt"
curl -fsS \
  -H 'Authorization: Bearer mcp-test-token' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"steamcmd_download_workshop_item","arguments":{"appId":"1158310","itemId":"999","targetSubdir":"mcp_rejected"}}}' \
  "http://127.0.0.1:${port}/mcp" > "${mcp_rejected_response}"
assert_contains "${mcp_rejected_response}" "over configured limit 10 KiB"
[[ ! -e "${tmp}/downloads/mcp_rejected" ]] || fail "rejected MCP workshop download should not create target directory"

assert_contains "${tmp}/steamcmd.log" "+@NoPromptForPassword 1"
assert_contains "${tmp}/steamcmd.log" "+DepotDownloadProgressTimeout 240"
assert_contains "${tmp}/steamcmd.log" "+csecManifestDownloadTimeout 240"
assert_contains "${tmp}/steamcmd.log" "+login test-user"
assert_contains "${tmp}/steamcmd.log" "+workshop_download_item 1158310 111 validate"
assert_contains "${tmp}/steamcmd.log" "+workshop_download_item 1158310 222 validate"
assert_contains "${tmp}/steamcmd.log" "+download_depot 1158310 1158311"
assert_contains "${tmp}/steamcmd.log" "+app_info_print 1158310"
assert_not_contains "${tmp}/steamcmd.log" "+download_depot 1158310 1158312"
assert_not_contains "${tmp}/steamcmd.log" "+workshop_download_item 1158310 999"

echo "steamcmd-sidecar behavior tests passed"
