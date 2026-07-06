#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# change_depot_password.sh — Change the VCF depot basic-auth password/user
#
# Changes the HTTP basic-auth credential on a depot server set up by any of
# the create_vcf9_depot_server_*.sh / setup_rhel_offline_all.sh scripts.
# The password lives in an htpasswd file — this just updates it (no need to
# re-run the full setup, no web-server reload required: nginx/apache read the
# htpasswd file on every request).
#
# Auto-detects the htpasswd file (nginx or apache, common names).
#
# Usage:
#   sudo bash change_depot_password.sh --password 'NewPass'
#   sudo bash change_depot_password.sh --user vcfdepot --password 'NewPass'
#   sudo bash change_depot_password.sh --htpasswd /etc/nginx/.htpasswd-vcf9 \
#     --user newuser --password 'NewPass' --remove-old olduser
# ===========================================================================

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.0"

HTPASSWD_FILE=""       # auto-detected if empty
USER_NAME=""           # if empty, use the only user already in the file
PASSWORD=""
REMOVE_OLD=""          # optionally delete this user after adding the new one

green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
info()   { green   "[INFO] $*"; }
warn()   { yellow  "[WARN] $*"; }
die()    { red     "[ERROR] $*"; exit 1; }
ok()     { green   "[ OK ] $*"; }

usage() {
  cat <<EOF
Usage: sudo bash ${SCRIPT_NAME} --password 'NEWPASS' [options]

Change the depot basic-auth password (and optionally the username).

Options:
  --password PASS    New password (required; prompted if omitted)
  --user USER        Username to set/update. Default: the existing user in the file
  --htpasswd PATH    htpasswd file. Default: auto-detect
  --remove-old USER  Delete this old username after setting the new one
  --help             Show help

Examples:
  # change password for the existing user
  sudo bash ${SCRIPT_NAME} --password 'MyNewP@ss'

  # change username too (add new, remove old)
  sudo bash ${SCRIPT_NAME} --user newadmin --password 'MyNewP@ss' --remove-old vcfdepot
EOF
}

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --password)   PASSWORD="${2:-}";      shift 2 ;;
      --user)       USER_NAME="${2:-}";     shift 2 ;;
      --htpasswd)   HTPASSWD_FILE="${2:-}"; shift 2 ;;
      --remove-old) REMOVE_OLD="${2:-}";    shift 2 ;;
      --help|-h)    usage; exit 0 ;;
      *) die "Unknown argument: $1 (run with --help)" ;;
    esac
  done
}

detect_htpasswd() {
  [[ -z "${HTPASSWD_FILE}" ]] || { [[ -f "${HTPASSWD_FILE}" ]] || die "Not found: ${HTPASSWD_FILE}"; return 0; }
  local candidates=(
    /etc/nginx/.htpasswd-vcf9
    /etc/apache2/.htpasswd-vcf9
    /etc/httpd/.htpasswd-vcf9
    /etc/nginx/.htpasswd-rhel10
  )
  for f in "${candidates[@]}"; do
    [[ -f "${f}" ]] && { HTPASSWD_FILE="${f}"; return 0; }
  done
  # last resort: any .htpasswd* under the web config dirs
  HTPASSWD_FILE="$(find /etc/nginx /etc/apache2 /etc/httpd -name '.htpasswd*' 2>/dev/null | head -1)"
  [[ -n "${HTPASSWD_FILE}" ]] || die "No htpasswd file found. Pass --htpasswd PATH."
}

existing_user() {
  # first username in the file (before the first ':')
  awk -F: 'NF>=2{print $1; exit}' "${HTPASSWD_FILE}" 2>/dev/null
}

main() {
  require_root
  parse_args "$@"
  command -v htpasswd >/dev/null 2>&1 || die "htpasswd not found (install apache2-utils / httpd-tools)"

  detect_htpasswd
  info "htpasswd file: ${HTPASSWD_FILE}"

  # default user = the one already in the file
  if [[ -z "${USER_NAME}" ]]; then
    USER_NAME="$(existing_user)"
    [[ -n "${USER_NAME}" ]] || die "Could not detect existing user; pass --user"
    info "User: ${USER_NAME} (existing)"
  else
    info "User: ${USER_NAME}"
  fi

  if [[ -z "${PASSWORD}" ]]; then
    read -rsp "New password for '${USER_NAME}': " PASSWORD; echo
    [[ -n "${PASSWORD}" ]] || die "Password cannot be empty"
  fi

  # backup, then set (update existing / add new — no -c so file is preserved)
  cp -a "${HTPASSWD_FILE}" "${HTPASSWD_FILE}.bak-$(date +%s)"
  htpasswd -b "${HTPASSWD_FILE}" "${USER_NAME}" "${PASSWORD}"
  ok "Password set for ${USER_NAME}"

  if [[ -n "${REMOVE_OLD}" && "${REMOVE_OLD}" != "${USER_NAME}" ]]; then
    htpasswd -D "${HTPASSWD_FILE}" "${REMOVE_OLD}" 2>/dev/null && ok "Removed old user ${REMOVE_OLD}" || warn "Old user ${REMOVE_OLD} not present"
  fi

  # keep ownership/perms sane for the web user
  local web_user="nginx"
  id www-data >/dev/null 2>&1 && web_user="www-data"
  chown "root:${web_user}" "${HTPASSWD_FILE}" 2>/dev/null || true
  chmod 640 "${HTPASSWD_FILE}" 2>/dev/null || true

  cat <<EOF

=======================================================================
 Depot password changed — DONE   v${SCRIPT_VERSION}
=======================================================================
  htpasswd : ${HTPASSWD_FILE}
  User     : ${USER_NAME}

No web-server reload needed (htpasswd is read per request).

IMPORTANT: if a VCF Installer / SDDC Manager connects to this depot over
HTTPS + basic auth, update its depot credentials too, or it will fail to
connect with the old password. (HTTP no-auth depots on :8888 are unaffected.)
EOF
}

main "$@"
