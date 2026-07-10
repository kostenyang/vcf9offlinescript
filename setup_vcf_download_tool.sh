#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# setup_vcf_download_tool.sh — Install the VCF Download Tool on a depot server
#
# The VCF Download Tool (vcf-download-tool) is what pulls VCF binaries from
# Broadcom into your offline depot. This script installs/sets it up on the
# depot server and creates a re-runnable download helper.
#
# ---------------------------------------------------------------------------
# STEP 0 — Get the tool tarball and UPLOAD it to the depot server first
# ---------------------------------------------------------------------------
# Download `vcf-download-tool-<version>.tar.gz` from the Broadcom Support
# Portal (Tools & Utilities), then copy it to the depot server:
#
#   # From Linux / macOS:
#   scp vcf-download-tool-9.1.0.0.*.tar.gz root@<DEPOT_IP>:/root/
#
#   # From Windows (PuTTY pscp):
#   pscp vcf-download-tool-9.1.0.0.*.tar.gz root@<DEPOT_IP>:/root/
#
#   # From Windows (OpenSSH scp):
#   scp vcf-download-tool-9.1.0.0.*.tar.gz root@<DEPOT_IP>:/root/
#
# Then SSH into the depot server and run THIS script pointing at the tarball.
# ---------------------------------------------------------------------------
#
# Usage (on the depot server):
#   sudo bash setup_vcf_download_tool.sh \
#     --tgz /root/vcf-download-tool-9.1.0.0.tar.gz \
#     --token '<YOUR_DEPOT_DOWNLOAD_TOKEN>' \
#     --depot-store /opt/vcf-depot/vcf9 \
#     --download            # optional: run the download right away
#
# The download token / activation code comes from the Broadcom Support Portal
# (Generate Download Token). Keep it secret — do NOT commit it anywhere.
# ===========================================================================

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.0"

VDT_TGZ=""
TOOLS_DIR="/opt/vcf-depot/tools"
DEPOT_STORE="/opt/vcf-depot/vcf9"
VCF_VERSION="9.1.0"
DOWNLOAD_TYPE="INSTALL"          # INSTALL | UPGRADE | ALL

TOKEN=""                        # --token '<value>'   (VCF 9.0/9.1 download token)
TOKEN_FILE=""                   # --token-file PATH
ACTIVATION_CODE_FILE=""         # --activation-code PATH (VCF 9.1 alt)

GEN_DEPOT_ID="false"            # --gen-depot-id  (some setups need a software depot ID)
DO_LIST="false"                 # --list          (list available binaries)
DO_DOWNLOAD="false"             # --download      (download binaries now)

green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
info()   { green   "[INFO] $*"; }
warn()   { yellow  "[WARN] $*"; }
die()    { red     "[ERROR] $*"; exit 1; }
ok()     { green   "[ OK ] $*"; }

usage() {
  cat <<EOF
Usage: sudo bash ${SCRIPT_NAME} --tgz PATH [options]

Install the VCF Download Tool on a depot server and create a download helper.
(Upload the tarball first — see STEP 0 in the script header.)

Required:
  --tgz PATH               Path to vcf-download-tool-*.tar.gz (already uploaded)

Credential (one of):
  --token VALUE            Depot download token string
  --token-file PATH        File containing the download token
  --activation-code PATH   activation-code.txt (VCF 9.1 alternative)

Options:
  --tools-dir PATH         Extract dir. Default: ${TOOLS_DIR}
  --depot-store PATH       Depot data root. Default: ${DEPOT_STORE}
  --vcf-version VERSION    VCF version. Default: ${VCF_VERSION}
  --type TYPE              INSTALL | UPGRADE | ALL. Default: ${DOWNLOAD_TYPE}
  --gen-depot-id           Run 'configuration generate --software-depot-id'
  --list                   List available binaries (does not download)
  --download               Download binaries now
  --help                   Show this help

Examples:
  # 1) Just install the tool + create the helper
  sudo bash ${SCRIPT_NAME} --tgz /root/vcf-download-tool-9.1.0.0.tar.gz \\
    --token '<TOKEN>'

  # 2) Install + list what's available
  sudo bash ${SCRIPT_NAME} --tgz /root/vcf-download-tool-9.1.0.0.tar.gz \\
    --token '<TOKEN>' --list

  # 3) Install + download everything for VCF 9.1.0 now
  sudo bash ${SCRIPT_NAME} --tgz /root/vcf-download-tool-9.1.0.0.tar.gz \\
    --token '<TOKEN>' --download
EOF
}

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tgz)             VDT_TGZ="${2:-}";              shift 2 ;;
      --tools-dir)       TOOLS_DIR="${2:-}";            shift 2 ;;
      --depot-store)     DEPOT_STORE="${2:-}";          shift 2 ;;
      --vcf-version)     VCF_VERSION="${2:-}";          shift 2 ;;
      --type)            DOWNLOAD_TYPE="${2:-}";        shift 2 ;;
      --token)           TOKEN="${2:-}";                shift 2 ;;
      --token-file)      TOKEN_FILE="${2:-}";           shift 2 ;;
      --activation-code) ACTIVATION_CODE_FILE="${2:-}"; shift 2 ;;
      --gen-depot-id)    GEN_DEPOT_ID="true";           shift 1 ;;
      --list)            DO_LIST="true";                shift 1 ;;
      --download)        DO_DOWNLOAD="true";            shift 1 ;;
      --help|-h)         usage; exit 0 ;;
      *) die "Unknown argument: $1 (run with --help)" ;;
    esac
  done
  [[ -n "${VDT_TGZ}" ]] || die "--tgz is required (upload the tarball first — see header)"
  [[ -f "${VDT_TGZ}" ]] || die "Tarball not found: ${VDT_TGZ}"
}

# ---------------------------------------------------------------------------
extract_tool() {
  info "Extracting ${VDT_TGZ} -> ${TOOLS_DIR}"
  mkdir -p "${TOOLS_DIR}"
  tar -xzf "${VDT_TGZ}" -C "${TOOLS_DIR}"
  ok "Extracted"
}

find_tool_bin() {
  find "${TOOLS_DIR}" -type f -name vcf-download-tool 2>/dev/null | head -1
}

verify_tool() {
  local bin; bin="$(find_tool_bin)"
  [[ -n "${bin}" ]] || die "vcf-download-tool binary not found under ${TOOLS_DIR}"
  chmod +x "${bin}"
  info "Tool version:"
  "${bin}" -v 2>&1 | grep -i version | head -1 || true
  echo "${bin}"
}

# Resolve credential file (write --token to a temp file if given as a string)
resolve_token_file() {
  if   [[ -n "${TOKEN_FILE}" ]]; then echo "${TOKEN_FILE}"
  elif [[ -n "${TOKEN}" ]]; then
    local f="/root/.vcf-download-token.txt"
    printf '%s\n' "${TOKEN}" > "${f}"; chmod 600 "${f}"; echo "${f}"
  else echo ""
  fi
}

# ---------------------------------------------------------------------------
gen_depot_id() {
  [[ "${GEN_DEPOT_ID}" == "true" ]] || return 0
  local bin; bin="$(find_tool_bin)"
  info "Generating software depot ID"
  "${bin}" configuration generate --software-depot-id 2>&1 || warn "depot-id generation returned non-zero (may not be required)"
}

# ---------------------------------------------------------------------------
create_helper() {
  local bin; bin="$(find_tool_bin)"
  local tokfile; tokfile="$(resolve_token_file)"
  local helper="/opt/vcf-depot/download-vcf-binaries.sh"

  info "Creating download helper: ${helper}"
  cat > "${helper}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# Auto-generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
VCF_VERSION="${VCF_VERSION}"
DEPOT_STORE="${DEPOT_STORE}"
TOOL_BIN="${bin}"
TOKEN_FILE="${tokfile}"
ACTIVATION_CODE_FILE="${ACTIVATION_CODE_FILE}"
DOWNLOAD_TYPE="${DOWNLOAD_TYPE}"

[[ -x "\${TOOL_BIN}" ]] || { echo "tool not found: \${TOOL_BIN}" >&2; exit 1; }

if   [[ -n "\${ACTIVATION_CODE_FILE}" && -f "\${ACTIVATION_CODE_FILE}" ]]; then
  CRED="--depot-download-activation-code-file \${ACTIVATION_CODE_FILE}"
elif [[ -n "\${TOKEN_FILE}" && -f "\${TOKEN_FILE}" ]]; then
  CRED="--depot-download-token-file \${TOKEN_FILE}"
else
  echo "No credential (token-file / activation-code) configured." >&2; exit 1
fi

# 'echo N' answers the tool's first-run CEIP(Y/N) prompt non-interactively
echo 'N' | "\${TOOL_BIN}" binaries download \${CRED} \\
  --vcf-version "\${VCF_VERSION}" \\
  --automated-install \\
  --depot-store "\${DEPOT_STORE}" \\
  --type "\${DOWNLOAD_TYPE}"
EOF
  chmod +x "${helper}"
  ok "Helper ready: ${helper}"
}

# ---------------------------------------------------------------------------
list_binaries() {
  [[ "${DO_LIST}" == "true" ]] || return 0
  local bin; bin="$(find_tool_bin)"
  local tokfile; tokfile="$(resolve_token_file)"
  [[ -n "${tokfile}" || -n "${ACTIVATION_CODE_FILE}" ]] || die "--list needs --token/--token-file/--activation-code"
  info "Listing available VCF ${VCF_VERSION} ${DOWNLOAD_TYPE} binaries"
  local cred
  [[ -n "${ACTIVATION_CODE_FILE}" ]] \
    && cred="--depot-download-activation-code-file ${ACTIVATION_CODE_FILE}" \
    || cred="--depot-download-token-file ${tokfile}"
  # 'echo N' answers the first-run CEIP(Y/N) prompt non-interactively
  echo 'N' | "${bin}" binaries list --sku VCF --vcf-version "${VCF_VERSION}" ${cred} \
    --type "${DOWNLOAD_TYPE}" --automated-install 2>&1 | tail -40
}

run_download() {
  [[ "${DO_DOWNLOAD}" == "true" ]] || return 0
  info "Downloading binaries (this can take a while)"
  /opt/vcf-depot/download-vcf-binaries.sh
}

print_summary() {
  local bin; bin="$(find_tool_bin)"
  cat <<EOF

=======================================================================
 VCF Download Tool installed — DONE   v${SCRIPT_VERSION}
=======================================================================
  Tool binary : ${bin}
  Depot store : ${DEPOT_STORE}
  Helper      : /opt/vcf-depot/download-vcf-binaries.sh

Next:
  # download / update binaries any time (idempotent — skips existing)
  bash /opt/vcf-depot/download-vcf-binaries.sh

  # list what's available
  ${bin} binaries list --sku VCF --vcf-version ${VCF_VERSION} \\
    --depot-download-token-file <TOKEN_FILE> --type ${DOWNLOAD_TYPE} --automated-install
EOF
}

main() {
  require_root
  parse_args "$@"
  info "${SCRIPT_NAME} v${SCRIPT_VERSION}"
  extract_tool
  verify_tool >/dev/null
  gen_depot_id
  create_helper
  list_binaries
  run_download
  print_summary
}

main "$@"
