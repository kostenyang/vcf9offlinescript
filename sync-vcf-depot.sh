#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# sync-vcf-depot.sh — Publish a VCF offline depot to a serving node
#
# Run on the *download-tool* machine (the internet-connected box that ran
# vcf-download-tool). Pushes the depot tree to a serving node (nginx/apache
# depot), fixes ownership/permissions there, reloads the web server, and
# verifies the directory structure matches 1:1.
#
# Source and target keep the SAME depot-store path so the PROD/... tree is
# identical on both sides (COMP/<component>, metadata/manifest,
# productVersionCatalog, vsan/hcl must not be renamed or re-nested).
#
# Companion to: create_vcf9_depot_server_v4_nginx.sh
# ===========================================================================

SCRIPT_NAME="$(basename "$0")"

DEPOT_STORE="/opt/vcf-depot/vcf9"     # depot-store root; PROD/ lives under it
TARGET_HOST=""                         # e.g. 10.0.0.61
TARGET_USER="root"
WEB_USER="www-data"                    # Ubuntu nginx=www-data; RHEL nginx/apache=nginx/apache
RELOAD_CMD="systemctl reload nginx"    # web server reload on target
DO_RELOAD="true"
FIX_PERMS="true"
DRY_RUN="false"
SSH_PORT="22"

green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
info()   { green   "[INFO] $*"; }
warn()   { yellow  "[WARN] $*"; }
die()    { red     "[ERROR] $*"; exit 1; }

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --target HOST [options]

Publish this machine's VCF offline depot to a serving node.

Required:
  --target HOST            Target serving node (IP or FQDN), e.g. 10.0.0.61

Options:
  --user USER              SSH user on target. Default: ${TARGET_USER}
  --depot-store PATH       Depot-store root on BOTH sides. Default: ${DEPOT_STORE}
  --web-user USER          Web user to own files on target. Default: ${WEB_USER}
  --reload-cmd "CMD"       Web server reload command on target. Default: "${RELOAD_CMD}"
  --no-reload              Do not reload the web server on target
  --no-perms               Do not chown/chmod on target
  --port PORT              SSH port. Default: ${SSH_PORT}
  --dry-run                rsync --dry-run (show what would transfer, change nothing)
  -h, --help               Show this help

Examples:
  # Push to the nginx depot at 10.0.0.61 (Ubuntu, www-data)
  sudo bash ${SCRIPT_NAME} --target 10.0.0.61

  # Preview only
  sudo bash ${SCRIPT_NAME} --target 10.0.0.61 --dry-run

  # RHEL target served by Apache
  sudo bash ${SCRIPT_NAME} --target depot.example.lab \\
    --web-user apache --reload-cmd "systemctl reload httpd"
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)      TARGET_HOST="${2:-}";  shift 2 ;;
      --user)        TARGET_USER="${2:-}";  shift 2 ;;
      --depot-store) DEPOT_STORE="${2:-}";  shift 2 ;;
      --web-user)    WEB_USER="${2:-}";     shift 2 ;;
      --reload-cmd)  RELOAD_CMD="${2:-}";   shift 2 ;;
      --no-reload)   DO_RELOAD="false";     shift 1 ;;
      --no-perms)    FIX_PERMS="false";     shift 1 ;;
      --port)        SSH_PORT="${2:-}";     shift 2 ;;
      --dry-run)     DRY_RUN="true";        shift 1 ;;
      -h|--help)     usage; exit 0 ;;
      *) die "Unknown argument: $1  (run with --help)" ;;
    esac
  done
  [[ -n "${TARGET_HOST}" ]] || die "--target is required"
}

main() {
  parse_args "$@"

  local src="${DEPOT_STORE}/PROD"
  local remote="${TARGET_USER}@${TARGET_HOST}"
  local dst="${remote}:${DEPOT_STORE}/PROD/"
  local ssh="ssh -p ${SSH_PORT}"

  [[ -d "${src}" ]] || die "Source depot not found: ${src}"

  info "Source : ${src}/"
  info "Target : ${dst}"
  info "SSH    : ${ssh}"

  # Ensure target tree exists so rsync lands content-to-content.
  if [[ "${DRY_RUN}" != "true" ]]; then
    ${ssh} "${remote}" "mkdir -p '${DEPOT_STORE}/PROD'"
  fi

  # 1) Transfer (content-to-content; trailing slashes matter).
  local rsync_opts=(-aH --info=progress2 --partial -e "${ssh}")
  [[ "${DRY_RUN}" == "true" ]] && rsync_opts+=(--dry-run)
  info "Syncing depot (rsync ${DRY_RUN:+--dry-run})..."
  rsync "${rsync_opts[@]}" "${src}/" "${dst}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    warn "Dry-run complete — no changes made, skipping perms/reload/verify."
    exit 0
  fi

  # 2) Fix ownership + permissions on target so the web user can read.
  if [[ "${FIX_PERMS}" == "true" ]]; then
    info "Fixing ownership (${WEB_USER}) + permissions on target"
    ${ssh} "${remote}" "
      chown -R '${WEB_USER}:${WEB_USER}' '${DEPOT_STORE}/PROD' &&
      find '${DEPOT_STORE}/PROD' -type d -exec chmod 0500 {} + &&
      find '${DEPOT_STORE}/PROD' -type f -exec chmod 0400 {} + &&
      { command -v restorecon >/dev/null 2>&1 && restorecon -R '${DEPOT_STORE}/PROD' || true; }
    "
  fi

  # 3) Reload web server on target.
  if [[ "${DO_RELOAD}" == "true" ]]; then
    info "Reloading web server on target: ${RELOAD_CMD}"
    ${ssh} "${remote}" "${RELOAD_CMD}" || warn "Reload failed — check the web server on target manually."
  fi

  # 4) Verify structure matches 1:1 (relative path trees).
  info "Verifying directory structure (source vs target)"
  local src_list dst_list
  src_list="$(cd "${src}" && find . | sort)"
  dst_list="$(${ssh} "${remote}" "cd '${DEPOT_STORE}/PROD' && find . | sort")"

  if diff <(printf '%s\n' "${src_list}") <(printf '%s\n' "${dst_list}") >/tmp/depot-diff.$$; then
    info "Structure identical — all $(printf '%s\n' "${src_list}" | grep -c .) entries present on target."
    rm -f "/tmp/depot-diff.$$"
  else
    warn "Differences found (< source-only  > target-only). First 40 lines:"
    head -n 40 "/tmp/depot-diff.$$" >&2
    warn "Full diff saved: /tmp/depot-diff.$$"
    warn "'<' = not yet on target (re-run to push). '>' = target-only (e.g. older cumulative builds) — usually fine."
  fi

  info "Done. Depot published to ${TARGET_HOST}."
}

main "$@"
