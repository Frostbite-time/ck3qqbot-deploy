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

assert_missing() {
  [[ ! -e "$1" ]] || fail "expected path to be missing: $1"
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -Fq -- "$pattern" "$file" || fail "expected ${file} to contain ${pattern}"
}

assert_line_count() {
  local file="$1"
  local pattern="$2"
  local expected="$3"
  local actual

  actual="$(grep -Fc -- "$pattern" "$file" || true)"
  [[ "${actual}" == "${expected}" ]] || fail "expected ${file} to contain ${pattern} ${expected} times, got ${actual}"
}

assert_order() {
  local first_file="$1"
  local first_pattern="$2"
  local second_file="$3"
  local second_pattern="$4"
  local first_line
  local second_line

  first_line="$(grep -Fn -- "$first_pattern" "$first_file" | head -1 | cut -d: -f1 || true)"
  second_line="$(grep -Fn -- "$second_pattern" "$second_file" | head -1 | cut -d: -f1 || true)"
  [[ -n "${first_line}" ]] || fail "expected ${first_file} to contain ${first_pattern}"
  [[ -n "${second_line}" ]] || fail "expected ${second_file} to contain ${second_pattern}"
  (( first_line < second_line )) || fail "expected ${first_pattern} in ${first_file} before ${second_pattern} in ${second_file}"
}

make_fake_tools() {
  local bin_dir="$1"
  mkdir -p "${bin_dir}"

  cat > "${bin_dir}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

method="GET"
data=""
url=""

while (($#)); do
  case "$1" in
    -X)
      method="$2"
      shift 2
      ;;
    --data)
      data="$2"
      shift 2
      ;;
    -H)
      shift 2
      ;;
    -fsS | -f | -s | -S)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

path_part="/${url#*://*/}"
state_dir="${FAKE_SIDECAR_STATE_DIR:?}"
log_file="${FAKE_SIDECAR_LOG:?}"
mkdir -p "${state_dir}"
printf '%s %s\n' "${method}" "${path_part}" >> "${log_file}"
if [[ -n "${FAKE_EVENT_LOG:-}" ]]; then
  printf 'SIDECAR %s %s\n' "${method}" "${path_part}" >> "${FAKE_EVENT_LOG}"
fi
if [[ -n "${data}" ]]; then
  printf 'DATA %s\n' "${data}" >> "${log_file}"
fi

next_task_id() {
  local counter_file="${state_dir}/counter"
  local next=1
  if [[ -f "${counter_file}" ]]; then
    next="$(<"${counter_file}")"
    next=$((next + 1))
  fi
  printf '%s\n' "${next}" > "${counter_file}"
  printf 'task-%s\n' "${next}"
}

write_task() {
  local id="$1"
  local state="$2"
  local error="${3:-}"
  local target_dir="${4:-}"
  jq -cn \
    --arg id "${id}" \
    --arg state "${state}" \
    --arg error "${error}" \
    --arg targetDir "${target_dir}" \
    '{
      id: $id,
      state: $state,
      error: (if $error == "" then null else $error end),
      targetDir: (if $targetDir == "" then null else $targetDir end),
      targetBytes: 123,
      outputTail: (if $error == "" then [] else ["fake steamcmd failure"] end)
    }' > "${state_dir}/${id}.json"
}

case "${method} ${path_part}" in
  "POST /v1/internal/tasks/check-login")
    id="$(next_task_id)"
    if [[ -n "${FAKE_SIDECAR_LOGIN_FAIL:-}" ]]; then
      write_task "${id}" "failed" "fake login failed"
    else
      write_task "${id}" "succeeded"
    fi
    jq -cn --arg id "${id}" '{id: $id, state: "queued"}'
    ;;
  "POST /v1/internal/tasks/download-depot")
    id="$(next_task_id)"
    target_dir="$(jq -r '.targetDir' <<< "${data}")"
    depot_id="$(jq -r '.depotId' <<< "${data}")"
    count_file="${state_dir}/depot_${depot_id}_attempts"
    attempt=1
    if [[ -f "${count_file}" ]]; then
      attempt="$(<"${count_file}")"
      attempt=$((attempt + 1))
    fi
    printf '%s\n' "${attempt}" > "${count_file}"
    if [[ -n "${FAKE_SIDECAR_UPDATE_FAIL:-}" ]]; then
      write_task "${id}" "failed" "fake download failed" "${target_dir}"
    elif [[ -n "${FAKE_SIDECAR_DEPOT_FAILS:-}" && "${attempt}" -le "${FAKE_SIDECAR_DEPOT_FAILS}" ]]; then
      mkdir -p "${target_dir}/stale"
      printf 'stale depot attempt %s
' "${attempt}" > "${target_dir}/stale/failed-attempt.txt"
      write_task "${id}" "failed" "fake depot transient failure" "${target_dir}"
    else
      if [[ -n "${FAKE_SIDECAR_DEPOT_GAME_ROOT:-}" ]]; then
        target_dir="${target_dir}/game"
      fi
      mkdir -p "${target_dir}/common" "${target_dir}/gfx"
      printf 'depot=%s keep\n' "${depot_id}" > "${target_dir}/common/script_${depot_id}.txt"
      printf 'delete\n' > "${target_dir}/gfx/model_${depot_id}.mesh"
      write_task "${id}" "succeeded" "" "${target_dir}"
    fi
    jq -cn --arg id "${id}" '{id: $id, state: "queued"}'
    ;;
  "POST /v1/internal/workshop-state/reset")
    jq -cn '{ok: true}'
    ;;
  "POST /v1/internal/tasks/download-workshop")
    id="$(next_task_id)"
    target_dir="$(jq -r '.targetDir' <<< "${data}")"
    item_id="$(jq -r '.itemId' <<< "${data}")"
    count_file="${state_dir}/workshop_${item_id}_attempts"
    attempt=1
    if [[ -f "${count_file}" ]]; then
      attempt="$(<"${count_file}")"
      attempt=$((attempt + 1))
    fi
    printf '%s\n' "${attempt}" > "${count_file}"
    if [[ -n "${FAKE_SIDECAR_UPDATE_FAIL:-}" ]]; then
      write_task "${id}" "failed" "fake workshop failed" "${target_dir}/${item_id}"
    elif [[ -n "${FAKE_SIDECAR_WORKSHOP_FAILS:-}" && "${attempt}" -le "${FAKE_SIDECAR_WORKSHOP_FAILS}" ]]; then
      mkdir -p "${target_dir}/${item_id}/stale"
      printf 'stale workshop attempt %s
' "${attempt}" > "${target_dir}/${item_id}/stale/failed-attempt.txt"
      write_task "${id}" "failed" "fake workshop transient failure" "${target_dir}/${item_id}"
    elif [[ -n "${FAKE_SIDECAR_WORKSHOP_EMPTY_SUCCESSES:-}" && "${attempt}" -le "${FAKE_SIDECAR_WORKSHOP_EMPTY_SUCCESSES}" ]]; then
      write_task "${id}" "succeeded" "" "${target_dir}/${item_id}"
    else
      mkdir -p "${target_dir}/${item_id}/common" "${target_dir}/${item_id}/gfx"
      printf 'keep\n' > "${target_dir}/${item_id}/common/mod.txt"
      printf 'delete\n' > "${target_dir}/${item_id}/gfx/model.mesh"
      write_task "${id}" "succeeded" "" "${target_dir}/${item_id}"
    fi
    jq -cn --arg id "${id}" '{id: $id, state: "queued"}'
    ;;
  GET\ /v1/internal/tasks/*)
    id="${path_part##*/}"
    cat "${state_dir}/${id}.json"
    ;;
  *)
    echo "unexpected fake sidecar request: ${method} ${path_part}" >&2
    exit 92
    ;;
esac
EOF

cat > "${bin_dir}/fake-pruner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_PRUNER_LOG:?}"
if [[ -n "${FAKE_EVENT_LOG:-}" ]]; then
  printf 'PRUNER %s\n' "$*" >> "${FAKE_EVENT_LOG}"
fi

if [[ -n "${FAKE_PRUNER_FAIL_PATTERN:-}" && "$*" == *"${FAKE_PRUNER_FAIL_PATTERN}"* ]]; then
  echo "fake pruner failure for ${FAKE_PRUNER_FAIL_PATTERN}" >&2
  exit 82
fi

report_dir=""
args=("$@")
for ((index = 0; index < ${#args[@]}; index++)); do
  if [[ "${args[$index]}" == "-report-dir" ]]; then
    index=$((index + 1))
    report_dir="${args[$index]}"
  fi
done

[[ -n "${report_dir}" ]] || exit 81
mkdir -p "${report_dir}"
printf 'fake pruner summary\n' > "${report_dir}/SUMMARY.txt"
EOF

  chmod +x "${bin_dir}/curl" "${bin_dir}/fake-pruner"
}

run_update() {
  local tmp="$1"
  shift

  env \
    PATH="${tmp}/bin:${PATH}" \
    CK3QQBOT_KNOWLEDGE_DIR="${tmp}/knowledge" \
    CK3QQBOT_UPDATE_STATE_DIR="${tmp}/update-state" \
    CK3QQBOT_REPORT_DIR="${tmp}/reports" \
    CK3QQBOT_PRUNE_CONFIG="${tmp}/config.json" \
    CK3QQBOT_PRUNER_BIN="${tmp}/bin/fake-pruner" \
    CK3QQBOT_STEAMCMD_API_URL="http://fake-sidecar:18032" \
    CK3QQBOT_STEAMCMD_INTERNAL_TOKEN="internal-test-token" \
    CK3QQBOT_STEAMCMD_TASK_POLL_SEC=0 \
    CK3QQBOT_STEAMCMD_RETRY_BACKOFF_SEC=0 \
    CK3QQBOT_BASE_GAME_DIR="${tmp}/knowledge/base_game" \
    CK3QQBOT_WORKSHOP_DIR="${tmp}/knowledge/workshop_mods" \
    CK3QQBOT_STEAM_USER="test-user" \
    CK3QQBOT_RUNTIME_CONFIRM_TIMEOUT_SEC=5 \
    CK3QQBOT_RUNTIME_CONFIRM_POLL_SEC=1 \
    FAKE_SIDECAR_STATE_DIR="${tmp}/sidecar-state" \
    FAKE_SIDECAR_LOG="${tmp}/sidecar.log" \
    FAKE_PRUNER_LOG="${tmp}/pruner.log" \
    FAKE_EVENT_LOG="${tmp}/events.log" \
    "$@" \
    "${repo_root}/scripts/update-now"
}

setup_tmp() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/update-state"
  make_fake_tools "${tmp}/bin"
  printf '{}\n' > "${tmp}/config.json"
  printf '%s\n' "${tmp}"
}

confirm_runtime_when_updating() {
  local tmp="$1"
  (
    for _ in {1..50}; do
      if [[ -e "${tmp}/update-state/.updating" ]]; then
        printf 'confirmed_at=test\n' > "${tmp}/update-state/.runtime-confirm"
        exit 0
      fi
      sleep 0.1
    done
    exit 1
  ) &
}

test_success_flow() {
  local tmp
  tmp="$(setup_tmp)"
  printf 'old failure\n' > "${tmp}/update-state/FAILED"
  confirm_runtime_when_updating "${tmp}"

  run_update "${tmp}" \
    CK3QQBOT_BASE_GAME_DEPOT_IDS="1158311,1158314" \
    CK3QQBOT_WORKSHOP_MOD_IDS="111,222" \
    CK3QQBOT_PRUNE_DRY_RUN=true \
    CK3QQBOT_MIN_FREE_KIB=0

  assert_exists "${tmp}/update-state/READY"
  assert_missing "${tmp}/update-state/FAILED"
  assert_missing "${tmp}/knowledge/READY"
  assert_missing "${tmp}/update-state/.updating"
  assert_missing "${tmp}/update-state/.runtime-confirm"
  assert_exists "${tmp}/knowledge/MANIFEST.txt"
  assert_exists "${tmp}/knowledge/SUMMARY.txt"
  assert_exists "${tmp}/reports/base_game/SUMMARY.txt"
  assert_exists "${tmp}/reports/workshop_111/SUMMARY.txt"
  assert_exists "${tmp}/reports/workshop_222/SUMMARY.txt"

  assert_contains "${tmp}/sidecar.log" "POST /v1/internal/tasks/check-login"
  assert_contains "${tmp}/sidecar.log" "POST /v1/internal/tasks/download-depot"
  assert_contains "${tmp}/sidecar.log" '"appId":"1158310"'
  assert_contains "${tmp}/sidecar.log" '"depotId":"1158311"'
  assert_contains "${tmp}/sidecar.log" '"depotId":"1158314"'
  assert_contains "${tmp}/sidecar.log" "\"targetDir\":\"${tmp}/knowledge/base_game\""
  assert_exists "${tmp}/knowledge/base_game/common/script_1158311.txt"
  assert_exists "${tmp}/knowledge/base_game/common/script_1158314.txt"
  assert_contains "${tmp}/sidecar.log" "POST /v1/internal/tasks/download-workshop"
  assert_contains "${tmp}/sidecar.log" '"itemId":"111"'
  assert_contains "${tmp}/sidecar.log" '"itemId":"222"'
  assert_contains "${tmp}/pruner.log" "-root base_game:single:${tmp}/knowledge/base_game"
  assert_contains "${tmp}/pruner.log" "-root workshop_mod:single:${tmp}/knowledge/workshop_mods/111"
  assert_contains "${tmp}/pruner.log" "-root workshop_mod:single:${tmp}/knowledge/workshop_mods/222"
  assert_contains "${tmp}/pruner.log" "-dry-run=true"
  assert_contains "${tmp}/knowledge/SUMMARY.txt" "CleanBeforeUpdate: false"
}

test_clean_before_update_removes_old_managed_files() {
  local tmp
  tmp="$(setup_tmp)"
  mkdir -p \
    "${tmp}/knowledge/base_game/common" \
    "${tmp}/knowledge/workshop_mods/old_mod/common" \
    "${tmp}/knowledge/workshop_mods/111/common"
  printf 'old base\n' > "${tmp}/knowledge/base_game/common/old_base.txt"
  printf 'old configured mod\n' > "${tmp}/knowledge/workshop_mods/111/common/old_mod.txt"
  printf 'old removed mod\n' > "${tmp}/knowledge/workshop_mods/old_mod/common/old_mod.txt"

  confirm_runtime_when_updating "${tmp}"

  run_update "${tmp}" \
    CK3QQBOT_CLEAN_BEFORE_UPDATE=true \
    CK3QQBOT_BASE_GAME_DEPOT_IDS="1158311" \
    CK3QQBOT_WORKSHOP_MOD_IDS="111" \
    CK3QQBOT_PRUNE_DRY_RUN=true \
    CK3QQBOT_MIN_FREE_KIB=0

  assert_missing "${tmp}/knowledge/base_game/common/old_base.txt"
  assert_missing "${tmp}/knowledge/workshop_mods/111/common/old_mod.txt"
  assert_missing "${tmp}/knowledge/workshop_mods/old_mod"
  assert_exists "${tmp}/knowledge/base_game/common/script_1158311.txt"
  assert_exists "${tmp}/knowledge/workshop_mods/111/common/mod.txt"
  assert_contains "${tmp}/pruner.log" "-root base_game:single:${tmp}/knowledge/base_game"
  assert_contains "${tmp}/pruner.log" "-root workshop_mod:single:${tmp}/knowledge/workshop_mods/111"
  assert_contains "${tmp}/knowledge/SUMMARY.txt" "CleanBeforeUpdate: true"
}

test_base_game_prunes_game_subdir_when_depot_uses_ck3_layout() {
  local tmp
  tmp="$(setup_tmp)"
  confirm_runtime_when_updating "${tmp}"

  run_update "${tmp}" \
    FAKE_SIDECAR_DEPOT_GAME_ROOT=1 \
    CK3QQBOT_BASE_GAME_DEPOT_IDS="1158311" \
    CK3QQBOT_WORKSHOP_MOD_IDS="" \
    CK3QQBOT_PRUNE_DRY_RUN=true \
    CK3QQBOT_MIN_FREE_KIB=0

  assert_exists "${tmp}/knowledge/base_game/game/common/script_1158311.txt"
  assert_contains "${tmp}/pruner.log" "-root base_game:single:${tmp}/knowledge/base_game/game"
}

test_empty_base_game_depots_skips_base_game_downloads() {
  local tmp
  tmp="$(setup_tmp)"
  confirm_runtime_when_updating "${tmp}"

  run_update "${tmp}" \
    CK3QQBOT_BASE_GAME_DEPOT_IDS="" \
    CK3QQBOT_WORKSHOP_MOD_IDS="111" \
    CK3QQBOT_PRUNE_DRY_RUN=true \
    CK3QQBOT_MIN_FREE_KIB=0

  assert_exists "${tmp}/update-state/READY"
  assert_missing "${tmp}/reports/base_game/SUMMARY.txt"
  assert_missing "${tmp}/knowledge/base_game/common/script_1158311.txt"
  assert_contains "${tmp}/sidecar.log" "POST /v1/internal/tasks/check-login"
  if grep -Fq "POST /v1/internal/tasks/download-depot" "${tmp}/sidecar.log"; then
    fail "expected empty CK3QQBOT_BASE_GAME_DEPOT_IDS to skip depot downloads"
  fi
  assert_contains "${tmp}/sidecar.log" "POST /v1/internal/tasks/download-workshop"
  assert_exists "${tmp}/knowledge/workshop_mods/111/common/mod.txt"
  assert_contains "${tmp}/pruner.log" "-root workshop_mod:single:${tmp}/knowledge/workshop_mods/111"
  assert_contains "${tmp}/knowledge/SUMMARY.txt" "BaseGameDepots: "
}

test_download_retries_clean_failed_item_state() {
  local tmp
  tmp="$(setup_tmp)"
  confirm_runtime_when_updating "${tmp}"

  run_update "${tmp}" \
    FAKE_SIDECAR_DEPOT_FAILS=2 \
    FAKE_SIDECAR_WORKSHOP_FAILS=2 \
    CK3QQBOT_BASE_GAME_DEPOT_IDS="1158311" \
    CK3QQBOT_WORKSHOP_MOD_IDS="111" \
    CK3QQBOT_STEAMCMD_DEPOT_ATTEMPTS=5 \
    CK3QQBOT_STEAMCMD_WORKSHOP_ATTEMPTS=5 \
    CK3QQBOT_PRUNE_DRY_RUN=true \
    CK3QQBOT_MIN_FREE_KIB=0

  assert_exists "${tmp}/update-state/READY"
  assert_line_count "${tmp}/sidecar.log" "POST /v1/internal/tasks/download-depot" 3
  assert_line_count "${tmp}/sidecar.log" "POST /v1/internal/tasks/download-workshop" 3
  assert_exists "${tmp}/knowledge/base_game/common/script_1158311.txt"
  assert_exists "${tmp}/knowledge/workshop_mods/111/common/mod.txt"
  assert_missing "${tmp}/knowledge/base_game/stale/failed-attempt.txt"
  assert_missing "${tmp}/knowledge/workshop_mods/111/stale/failed-attempt.txt"
  assert_line_count "${tmp}/sidecar.log" "POST /v1/internal/workshop-state/reset" 4
  assert_contains "${tmp}/knowledge/SUMMARY.txt" "DepotAttempts: 5"
  assert_contains "${tmp}/knowledge/SUMMARY.txt" "WorkshopAttempts: 5"
}

test_workshop_empty_success_retries_clean_failed_item_state() {
  local tmp
  tmp="$(setup_tmp)"
  confirm_runtime_when_updating "${tmp}"

  run_update "${tmp}" \
    FAKE_SIDECAR_WORKSHOP_EMPTY_SUCCESSES=2 \
    CK3QQBOT_BASE_GAME_DEPOT_IDS="" \
    CK3QQBOT_WORKSHOP_MOD_IDS="3034473189" \
    CK3QQBOT_STEAMCMD_WORKSHOP_ATTEMPTS=5 \
    CK3QQBOT_PRUNE_DRY_RUN=true \
    CK3QQBOT_MIN_FREE_KIB=0

  assert_exists "${tmp}/update-state/READY"
  assert_line_count "${tmp}/sidecar.log" "POST /v1/internal/tasks/download-workshop" 3
  assert_line_count "${tmp}/sidecar.log" "POST /v1/internal/workshop-state/reset" 4
  assert_exists "${tmp}/knowledge/workshop_mods/3034473189/common/mod.txt"
  assert_contains "${tmp}/pruner.log" "-root workshop_mod:single:${tmp}/knowledge/workshop_mods/3034473189"
  assert_contains "${tmp}/knowledge/SUMMARY.txt" "WorkshopAttempts: 5"
}

test_workshop_state_is_reset_before_batch_and_after_each_prune() {
  local tmp
  tmp="$(setup_tmp)"
  confirm_runtime_when_updating "${tmp}"

  run_update "${tmp}" \
    CK3QQBOT_BASE_GAME_DEPOT_IDS="" \
    CK3QQBOT_WORKSHOP_MOD_IDS="111,222" \
    CK3QQBOT_PRUNE_DRY_RUN=false \
    CK3QQBOT_MIN_FREE_KIB=0

  assert_exists "${tmp}/update-state/READY"
  assert_line_count "${tmp}/sidecar.log" "POST /v1/internal/workshop-state/reset" 3
  assert_order \
    "${tmp}/events.log" "SIDECAR POST /v1/internal/workshop-state/reset" \
    "${tmp}/events.log" "SIDECAR POST /v1/internal/tasks/download-workshop"

  first_prune_line="$(grep -Fn -- "PRUNER -config ${tmp}/config.json -report-dir ${tmp}/reports/workshop_111" "${tmp}/events.log" | head -1 | cut -d: -f1)"
  second_download_line="$(grep -Fn -- "SIDECAR POST /v1/internal/tasks/download-workshop" "${tmp}/events.log" | tail -1 | cut -d: -f1)"
  reset_after_first_prune_line="$(awk -v start="${first_prune_line}" 'NR > start && /SIDECAR POST \/v1\/internal\/workshop-state\/reset/ { print NR; exit }' "${tmp}/events.log")"
  [[ -n "${reset_after_first_prune_line}" ]] || fail "expected workshop state reset after first workshop prune"
  (( first_prune_line < reset_after_first_prune_line && reset_after_first_prune_line < second_download_line )) || \
    fail "expected first workshop to be pruned and reset before second workshop download"
}

test_steam_failure_clears_update_markers_and_records_failed_marker() {
  local tmp
  tmp="$(setup_tmp)"
  confirm_runtime_when_updating "${tmp}"

  if run_update "${tmp}" \
    FAKE_SIDECAR_UPDATE_FAIL=1 \
    CK3QQBOT_WORKSHOP_MOD_IDS="" \
    CK3QQBOT_MIN_FREE_KIB=0; then
    fail "expected updater to fail"
  fi

  assert_missing "${tmp}/update-state/.updating"
  assert_missing "${tmp}/update-state/.runtime-confirm"
  assert_exists "${tmp}/update-state/FAILED"
  assert_missing "${tmp}/update-state/READY"
  assert_missing "${tmp}/knowledge/READY"
  assert_contains "${tmp}/update-state/FAILED" "failed_at="
  assert_contains "${tmp}/update-state/FAILED" "exit_code=37"
  assert_contains "${tmp}/update-state/FAILED" "failed_phase=download_base_game_depot"
  assert_contains "${tmp}/update-state/FAILED" "failed_item_kind=base_game_depot"
  assert_contains "${tmp}/update-state/FAILED" "failed_item=1158311"
  assert_contains "${tmp}/update-state/FAILED" "failed_attempt=10"
  assert_contains "${tmp}/update-state/FAILED" "failed_max_attempts=10"
  assert_contains "${tmp}/update-state/FAILED" "planned_base_game_depots=1158311"
  assert_contains "${tmp}/update-state/FAILED" "completed_base_game_downloads="
  assert_contains "${tmp}/update-state/FAILED" "remaining_base_game_depots=1158311"
  assert_line_count "${tmp}/sidecar.log" "POST /v1/internal/tasks/download-depot" 10
}

test_prune_failure_records_completed_download_and_remaining_item() {
  local tmp
  tmp="$(setup_tmp)"
  confirm_runtime_when_updating "${tmp}"

  if run_update "${tmp}" \
    FAKE_PRUNER_FAIL_PATTERN="base_game:single:${tmp}/knowledge/base_game" \
    CK3QQBOT_BASE_GAME_DEPOT_IDS="1158311" \
    CK3QQBOT_WORKSHOP_MOD_IDS="111" \
    CK3QQBOT_PRUNE_DRY_RUN=false \
    CK3QQBOT_MIN_FREE_KIB=0; then
    fail "expected updater to fail during base game prune"
  fi

  assert_exists "${tmp}/update-state/FAILED"
  assert_missing "${tmp}/update-state/READY"
  assert_contains "${tmp}/update-state/FAILED" "exit_code=82"
  assert_contains "${tmp}/update-state/FAILED" "failed_phase=prune_base_game"
  assert_contains "${tmp}/update-state/FAILED" "failed_item_kind=base_game_depot"
  assert_contains "${tmp}/update-state/FAILED" "failed_item=1158311"
  assert_contains "${tmp}/update-state/FAILED" "failed_label=prune base_game 1158311"
  assert_contains "${tmp}/update-state/FAILED" "planned_base_game_depots=1158311"
  assert_contains "${tmp}/update-state/FAILED" "planned_workshop_mods=111"
  assert_contains "${tmp}/update-state/FAILED" "completed_base_game_downloads=1158311"
  assert_contains "${tmp}/update-state/FAILED" "completed_base_game_prunes="
  assert_contains "${tmp}/update-state/FAILED" "completed_workshop_downloads="
  assert_contains "${tmp}/update-state/FAILED" "remaining_base_game_depots=1158311"
  assert_contains "${tmp}/update-state/FAILED" "remaining_workshop_mods=111"
}

test_login_check_failure_does_not_start_update() {
  local tmp
  tmp="$(setup_tmp)"

  if run_update "${tmp}" \
    FAKE_SIDECAR_LOGIN_FAIL=1 \
    CK3QQBOT_WORKSHOP_MOD_IDS="" \
    CK3QQBOT_MIN_FREE_KIB=0; then
    fail "expected updater to fail during login check"
  fi

  assert_missing "${tmp}/update-state/.updating"
  assert_missing "${tmp}/update-state/READY"
  assert_missing "${tmp}/knowledge/READY"
  assert_contains "${tmp}/sidecar.log" "POST /v1/internal/tasks/check-login"
}

test_disk_guard_runs_before_marker() {
  local tmp
  tmp="$(setup_tmp)"

  if run_update "${tmp}" CK3QQBOT_MIN_FREE_KIB=999999999999999; then
    fail "expected updater to fail on disk guard"
  fi

  assert_missing "${tmp}/update-state/.updating"
  assert_missing "${tmp}/update-state/READY"
  assert_missing "${tmp}/knowledge/READY"
}

test_existing_marker_refuses_to_run() {
  local tmp
  tmp="$(setup_tmp)"
  mkdir -p "${tmp}/update-state"
  printf 'stale\n' > "${tmp}/update-state/.updating"

  if run_update "${tmp}" CK3QQBOT_MIN_FREE_KIB=0; then
    fail "expected updater to refuse existing marker"
  fi

  assert_contains "${tmp}/update-state/.updating" "stale"
  assert_missing "${tmp}/update-state/READY"
  assert_missing "${tmp}/knowledge/READY"
}

test_existing_entry_lock_refuses_to_run() {
  local tmp
  tmp="$(setup_tmp)"
  mkdir -p "${tmp}/update-state/.update-lock"

  if run_update "${tmp}" CK3QQBOT_MIN_FREE_KIB=0; then
    fail "expected updater to refuse existing entry lock"
  fi

  assert_missing "${tmp}/update-state/.updating"
  assert_missing "${tmp}/update-state/READY"
  assert_missing "${tmp}/knowledge/READY"
  assert_missing "${tmp}/sidecar.log"
}

test_missing_runtime_confirm_fails() {
  local tmp
  tmp="$(setup_tmp)"

  if run_update "${tmp}" \
    CK3QQBOT_WORKSHOP_MOD_IDS="" \
    CK3QQBOT_RUNTIME_CONFIRM_TIMEOUT_SEC=1 \
    CK3QQBOT_MIN_FREE_KIB=0; then
    fail "expected updater to fail when runtime does not confirm"
  fi

  assert_missing "${tmp}/update-state/.updating"
  assert_missing "${tmp}/update-state/.runtime-confirm"
  assert_exists "${tmp}/update-state/FAILED"
  assert_contains "${tmp}/update-state/FAILED" "exit_code=39"
  assert_missing "${tmp}/update-state/READY"
  assert_missing "${tmp}/knowledge/READY"
}

test_success_flow
test_clean_before_update_removes_old_managed_files
test_base_game_prunes_game_subdir_when_depot_uses_ck3_layout
test_empty_base_game_depots_skips_base_game_downloads
test_download_retries_clean_failed_item_state
test_workshop_empty_success_retries_clean_failed_item_state
test_workshop_state_is_reset_before_batch_and_after_each_prune
test_login_check_failure_does_not_start_update
test_steam_failure_clears_update_markers_and_records_failed_marker
test_prune_failure_records_completed_download_and_remaining_item
test_disk_guard_runs_before_marker
test_existing_marker_refuses_to_run
test_existing_entry_lock_refuses_to_run
test_missing_runtime_confirm_fails

echo "update-now behavior tests passed"
