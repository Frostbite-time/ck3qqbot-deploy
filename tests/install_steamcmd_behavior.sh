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

tmp="$(mktemp -d)"
package="${tmp}/package"
release="${tmp}/release"
install_root="${tmp}/opt/steamcmd"
bin_dir="${tmp}/usr/local/bin"
fake_bin="${tmp}/bin"

mkdir -p "${package}" "${release}" "${fake_bin}"

cat > "${package}/steamcmd.sh" <<'EOF'
#!/usr/bin/env sh
echo "steamcmd fake"
EOF
chmod +x "${package}/steamcmd.sh"

tar -czf "${release}/steamcmd_linux.tar.gz" -C "${package}" .
archive_digest="$(sha256sum "${release}/steamcmd_linux.tar.gz" | awk '{print $1}')"

cat > "${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

out=""
url=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -o)
      shift
      out="$1"
      ;;
    -*)
      ;;
    *)
      url="$1"
      ;;
  esac
  shift
done

[[ -n "${out}" ]] || exit 2
case "${url}" in
  file://*)
    cp "${url#file://}" "${out}"
    ;;
  *)
    exit 3
    ;;
esac
EOF
chmod +x "${fake_bin}/curl"

PATH="${fake_bin}:${PATH}" \
  STEAMCMD_URL="file://${release}/steamcmd_linux.tar.gz" \
  STEAMCMD_SHA256="${archive_digest}" \
  STEAMCMD_INSTALL_ROOT="${install_root}" \
  STEAMCMD_BIN_DIR="${bin_dir}" \
  "${repo_root}/scripts/install-steamcmd"

assert_exists "${install_root}/steamcmd.sh"
assert_exists "${bin_dir}/steamcmd"
"${bin_dir}/steamcmd" | grep -Fq "steamcmd fake"

echo "install-steamcmd behavior tests passed"

